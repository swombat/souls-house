require "minitest/autorun"
require "erb"
require "yaml"
require "pathname"
require "kamal"
require "tmpdir"
require_relative "../../config/house"
require_relative "../../lib/house/stone_tls"

# No Rails fixtures or real installation files: exercise the rendered template
# through the pinned Kamal parser and its secret resolver.
class StoneDeployTest < Minitest::Test

  ROOT = Pathname.new(File.expand_path("../..", __dir__))

  def test_unconfigured_or_blank_domain_keeps_automatic_house_tls
    [ nil, "", "  " ].each do |domain|
      with_deploy({ "SOULSHOUSE_STONES_DOMAIN" => domain }, "") do |config|
        assert_equal [ "house.example.org" ], config.dig("proxy", "hosts")
        assert_equal true, config.dig("proxy", "ssl")
        refute config.fetch("servers").key?("stones")
        refute config.dig("env", "clear").key?("SOULSHOUSE_STONES_DOMAIN")
      end
    end
  end

  def test_configured_domain_adds_only_the_wildcard_and_preserves_house_identity
    with_deploy("SOULSHOUSE_STONES_DOMAIN" => " EXAMPLE.NET ") do |config|
      assert_equal [ "house.example.org" ], config.dig("proxy", "hosts")
      assert_equal true, config.dig("proxy", "ssl")
      assert_equal [ "*.example.net" ], config.dig("servers", "stones", "proxy", "hosts")
      assert_equal "example.net", config.dig("env", "clear", "SOULSHOUSE_STONES_DOMAIN")
      assert_equal "https://house.example.org", config.dig("env", "clear", "SOULSHOUSE_PUBLIC_URL")
      assert_equal 3000, config.dig("proxy", "app_port")
      assert_equal 120, config.dig("proxy", "response_timeout")
      assert_equal({
        "certificate_pem" => "STONES_TLS_CERTIFICATE_PEM",
        "private_key_pem" => "STONES_TLS_PRIVATE_KEY_PEM"
      }, config.dig("servers", "stones", "proxy", "ssl"))
      refute_includes config.dig("env", "secret"), "STONES_TLS_PRIVATE_KEY_PEM"
      refute_includes config.dig("env", "secret"), "STONES_TLS_CERTIFICATE_PEM"
      refute_includes config.to_s, "PORKBUN"
    end
  end

  def test_pinned_kamal_passes_wildcard_and_static_certificate_paths_to_proxy
    with_deploy("SOULSHOUSE_STONES_DOMAIN" => "example.net") do |config|
      with_kamal(config, certificate_secrets) do |kamal|
        assert_equal "2.12.0", Gem.loaded_specs.fetch("kamal").version.to_s
        web = kamal.role("web")
        stones = kamal.role("stones")
        assert_equal web.hosts, stones.hosts
        assert_equal "souls-house-web", web.container_prefix
        assert_equal "souls-house-stones", stones.container_prefix
        selected = Kamal::Commander::Specifics.new(kamal, nil, nil)
        assert_equal %w[jobs stones web], selected.roles_on(stones.primary_host).map(&:name).sort
        web_run = Kamal::Commands::App.new(kamal, role: web, host: web.primary_host).run
        stones_run = Kamal::Commands::App.new(kamal, role: stones, host: stones.primary_host).run
        assert_includes web_run, kamal.absolute_image
        assert_includes stones_run, kamal.absolute_image
        assert_includes Kamal::Commands::App.new(kamal, role: stones).deploy(target: "test").join(" "),
          "deploy souls-house-stones"
        assert web.proxy.ssl?
        refute web.proxy.custom_ssl_certificate?
        assert_nil web.proxy.host_tls_cert
        assert_nil web.proxy.host_tls_key
        refute web.proxy.deploy_options.key?(:"tls-certificate-path")
        refute web.proxy.deploy_options.key?(:"tls-private-key-path")
        assert_equal [ "house.example.org" ], web.proxy.deploy_options.fetch(:host)
        proxy = stones.proxy
        assert proxy.custom_ssl_certificate?
        assert_equal test_certificate.to_pem, proxy.certificate_pem_content
        assert_equal test_key.private_to_pem, proxy.private_key_pem_content
        options = proxy.deploy_options
        assert_equal [ "*.example.net" ], options.fetch(:host)
        assert_equal true, options.fetch(:tls)
        assert_equal "/home/kamal-proxy/.apps-config/souls-house/tls/stones/cert.pem", options.fetch(:"tls-certificate-path")
        assert_equal "/home/kamal-proxy/.apps-config/souls-house/tls/stones/key.pem", options.fetch(:"tls-private-key-path")
        assert_match %r{/tls/stones/cert\.pem\z}, proxy.host_tls_cert
        assert_match %r{/tls/stones/key\.pem\z}, proxy.host_tls_key
        assert_equal 3000, proxy.app_port
        assert_equal "120s", options.fetch(:"target-timeout")
        assert_includes proxy.deploy_command_args(target: "app"), '--host="*.example.net"'
        refute kamal.role("jobs").running_proxy?
      end
    end
  end

  def test_missing_certificate_secret_raises_without_automatic_tls_fallback
    assert_missing_secret "STONES_TLS_CERTIFICATE_PEM", certificate_secrets(certificate: nil)
  end

  def test_missing_private_key_secret_raises_without_automatic_tls_fallback
    assert_missing_secret "STONES_TLS_PRIVATE_KEY_PEM", certificate_secrets(private_key: nil)
  end

  def test_pinned_kamal_resolves_multiline_pem_from_its_secrets_file
    with_deploy("SOULSHOUSE_STONES_DOMAIN" => "example.net") do |config|
      with_kamal(config, certificate_secrets) do |kamal|
        proxy = kamal.role("stones").proxy
        assert_equal test_certificate.to_pem, proxy.certificate_pem_content
        assert_equal test_key.private_to_pem, proxy.private_key_pem_content
      end
    end
  end

  def test_template_rejects_expired_and_not_yet_valid_certificates
    [
      build_certificate(not_before: Time.now - 120, not_after: Time.now - 60),
      build_certificate(not_before: Time.now + 60, not_after: Time.now + 120)
    ].each do |certificate|
      assert_preflight_rejects certificate_secrets(certificate: certificate.to_pem), "expired or not yet valid"
    end
  end

  def test_wildcard_only_certificate_does_not_need_house_identity
    with_deploy("SOULSHOUSE_STONES_DOMAIN" => "example.net") do |config|
      assert_equal true, config.dig("proxy", "ssl")
    end
  end

  def test_template_requires_a_wildcard_san_not_just_the_probe_hostname
    certificate = build_certificate(names: [ "DNS:house.example.org", "DNS:stone-tls-preflight.example.net" ])
    assert_preflight_rejects certificate_secrets(certificate: certificate.to_pem), "explicit wildcard DNS SAN"
  end

  def test_template_rejects_a_wildcard_for_the_wrong_domain
    certificate = build_certificate(names: [ "DNS:house.example.org", "DNS:*.other.example.net" ])
    assert_preflight_rejects certificate_secrets(certificate: certificate.to_pem), "explicit wildcard DNS SAN"
  end

  def test_template_rejects_a_mismatched_private_key
    other_key = OpenSSL::PKey::EC.generate("prime256v1")
    assert_preflight_rejects certificate_secrets(private_key: other_key.private_to_pem), "do not match"
  end

  def test_template_rejects_public_or_encrypted_keys_and_malformed_pem_without_echoing_input
    [
      test_key.public_to_pem,
      test_key.private_to_pem(OpenSSL::Cipher.new("aes-256-cbc"), "test-password"),
      "private-do-not-echo"
    ].each do |key|
      assert_preflight_rejects certificate_secrets(private_key: key), "invalid, or encrypted"
    end
    assert_preflight_rejects certificate_secrets(certificate: "certificate-do-not-echo"), "invalid, or encrypted"
  end

  def test_stones_role_is_small_and_cannot_start_inline_jobs_or_prepare_database
    with_deploy("SOULSHOUSE_STONES_DOMAIN" => "example.net", "HOUSE_STORAGE" => "local") do |config|
      with_kamal(config, certificate_secrets) do |kamal|
        role = kamal.role("stones")
        assert_equal "env -u SOLID_QUEUE_IN_PUMA bundle exec puma -C config/puma.rb", role.cmd
        assert_equal "0", role.env(role.primary_host).clear.fetch("WEB_CONCURRENCY")
        assert_equal "5", role.env(role.primary_host).clear.fetch("RAILS_MAX_THREADS")
        assert_equal "1", role.env(role.primary_host).clear.fetch("SOULSHOUSE_STONES_ONLY")
        %w[web jobs].each do |name|
          other = kamal.role(name)
          refute other.env(other.primary_host).clear.key?("SOULSHOUSE_STONES_ONLY")
        end
        assert_equal "./bin/rails solid_queue:start", kamal.role("jobs").cmd
        refute_includes role.option_args.join(" "), "docker.sock"
        assert_includes role.option_args.join(" "), "souls_house_storage:/rails/storage:ro"
        assert_equal "768m", config.dig("servers", "stones", "options", "memory")
        assert_equal 1, config.dig("servers", "stones", "options", "cpus")
      end
    end
    with_deploy("SOULSHOUSE_STONES_DOMAIN" => "example.net") do |config|
      refute config.dig("servers", "stones", "options").key?("volume")
    end
  end

  private

  def assert_missing_secret(name, secrets)
    error = assert_raises(Kamal::ConfigurationError) do
      with_deploy({ "SOULSHOUSE_STONES_DOMAIN" => "example.net" }, secrets) { flunk "must fail before deployment" }
    end
    assert_includes error.message, name
  end

  def assert_preflight_rejects(secrets, message)
    error = assert_raises(House::StoneTls::InvalidCertificate) do
      with_deploy({ "SOULSHOUSE_STONES_DOMAIN" => "example.net" }, secrets) { flunk "must fail before deployment" }
    end
    assert_includes error.message, message
    refute_includes error.message, "BEGIN"
    refute_includes error.message, "do-not-echo"
  end

  def test_key
    @test_key ||= OpenSSL::PKey::EC.generate("prime256v1")
  end

  def test_certificate
    @test_certificate ||= build_certificate
  end

  def build_certificate(names: [ "DNS:*.example.net" ],
    not_before: Time.now - 60, not_after: Time.now + 86_400)
    certificate = OpenSSL::X509::Certificate.new
    certificate.version = 2
    certificate.serial = 1
    certificate.subject = certificate.issuer = OpenSSL::X509::Name.parse("/CN=Deployment test")
    certificate.public_key = test_key
    certificate.not_before = not_before
    certificate.not_after = not_after
    certificate.add_extension(OpenSSL::X509::ExtensionFactory.new.create_extension("subjectAltName", names.join(",")))
    certificate.sign(test_key, OpenSSL::Digest.new("SHA256"))
    certificate
  end

  def certificate_secrets(certificate: test_certificate.to_pem, private_key: test_key.private_to_pem)
    { "STONES_TLS_CERTIFICATE_PEM" => certificate, "STONES_TLS_PRIVATE_KEY_PEM" => private_key }.compact.map do |name, value|
      "#{name}=\"#{value}\"\n"
    end.join
  end

  def with_kamal(config, secrets)
    Dir.mktmpdir("stone-deploy-test") do |directory|
      path = File.join(directory, "secrets")
      File.write(path, secrets)
      yield Kamal::Configuration.new(config.symbolize_keys.merge(secrets_path: path), version: "test")
    end
  end

  def with_deploy(overrides, secrets = certificate_secrets)
    example = House.parse(File.read(ROOT.join("config/house.env.example")))
    keys = (example.keys + %w[MNEMODYNE_EMBEDDING_IMAGE_DIGEST KAMAL_DESTINATION]).uniq
    previous = keys.to_h { |key| [ key, ENV[key] ] }
    keys.each { |key| ENV.delete(key) }
    example.merge("HOUSE_EMBEDDINGS_DIGEST" => "sha256:#{"0" * 64}").merge(overrides).each do |key, value|
      ENV[key] = value
    end
    Dir.mktmpdir("stone-template-test") do |directory|
      Dir.mkdir(File.join(directory, ".kamal"))
      File.write(File.join(directory, ".kamal/secrets"), secrets)
      Dir.chdir(directory) do
        rendered = ERB.new(File.read(ROOT.join("config/deploy.yml")), trim_mode: "-").result
        yield YAML.safe_load(rendered)
      end
    end
  ensure
    previous&.each { |key, value| ENV[key] = value }
  end

end
