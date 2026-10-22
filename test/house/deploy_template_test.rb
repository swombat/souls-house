require "test_helper"
require Rails.root.join("config/house")

# Phase 1 of the forkable-house plan (docs/.bak/2026-09-07-forkable-house-plan-from-lume.md):
# config/deploy.yml is an ERB template over HOUSE_* env, and nothing else in
# the repository should name a specific installation.
class DeployTemplateTest < ActiveSupport::TestCase

  UPSTREAM_IDENTIFIERS = %w[
    dtenner
    95.217.118.47
    swombat
    souls.house
    12222
    988
    ssh://misc
    helix-kit-web
  ].freeze

  DUMMY_DIGEST = "sha256:#{"0" * 64}".freeze

  test "rendering with only house.env.example (plus a digest) succeeds and names no upstream identifier" do
    with_env(example_env.merge("HOUSE_EMBEDDINGS_DIGEST" => DUMMY_DIGEST)) do
      rendered = render_deploy_yml

      UPSTREAM_IDENTIFIERS.each do |identifier|
        assert_not_includes rendered, identifier, "expected the example-rendered deploy.yml not to mention #{identifier}"
      end

      assert YAML.safe_load(rendered).present?
    end
  end

  test "an explicit remote builder never compiles locally on a matching architecture" do
    with_env(example_env.merge("HOUSE_EMBEDDINGS_DIGEST" => DUMMY_DIGEST,
                              "HOUSE_BUILDER_REMOTE" => "ssh://deploy@builder.example:22")) do
      builder = YAML.safe_load(render_deploy_yml).fetch("builder")
      assert_equal "ssh://deploy@builder.example:22", builder.fetch("remote")
      assert_equal false, builder.fetch("local")
    end
    with_env(example_env.merge("HOUSE_EMBEDDINGS_DIGEST" => DUMMY_DIGEST)) do
      builder = YAML.safe_load(render_deploy_yml).fetch("builder")
      assert_not builder.key?("local")
      assert_not builder.key?("remote")
    end
  end

  test "asynchronous admission forwards the explicit installation choice" do
    [ "0", "1" ].each do |value|
      with_env(example_env.merge("HOUSE_EMBEDDINGS_DIGEST" => DUMMY_DIGEST, "SOULSHOUSE_ASYNC_TURNS" => value)) do
        runtime = YAML.safe_load(render_deploy_yml).fetch("env").fetch("clear")
        assert_equal value, runtime.fetch("SOULSHOUSE_ASYNC_TURNS")
      end
    end
  end

  test "missing or invalid asynchronous admission choice fails deployment" do
    [ nil, "", "true", "false", "2", " 1 " ].each do |value|
      with_env(example_env.merge("HOUSE_EMBEDDINGS_DIGEST" => DUMMY_DIGEST, "SOULSHOUSE_ASYNC_TURNS" => value)) do
        error = assert_raises(RuntimeError) { render_deploy_yml }
        assert_includes error.message, "SOULSHOUSE_ASYNC_TURNS"
        assert_includes error.message, "config/house.env"
      end
    end
  end

  test "rendering without house.env raises, pointing at house.env" do
    with_env(example_env.except("HOUSE_DOMAIN", "HOUSE_HOST")) do
      error = assert_raises(RuntimeError) { render_deploy_yml }
      assert_includes error.message, "house.env"
    end
  end

  test "deployment wires the fork domain into mailer links as well as public callbacks" do
    with_env(example_env.merge("HOUSE_DOMAIN" => "my-house.example", "HOUSE_EMBEDDINGS_DIGEST" => DUMMY_DIGEST)) do
      runtime = YAML.safe_load(render_deploy_yml).fetch("env").fetch("clear")
      assert_equal "https://my-house.example", runtime.fetch("SOULSHOUSE_PUBLIC_URL")
      assert_equal "my-house.example", runtime.fetch("SOULSHOUSE_DOMAIN")
      options = { host: runtime.fetch("SOULSHOUSE_DOMAIN") }
      assert_equal "my-house.example", URI(Rails.application.routes.url_helpers.email_confirmation_url(token: "test", **options)).host
      assert_equal "my-house.example", URI(Rails.application.routes.url_helpers.edit_password_url("test", **options)).host
    end
  end

  test "a fork's source repository reaches the app, and is absent when blank" do
    with_env(example_env.merge("HOUSE_EMBEDDINGS_DIGEST" => DUMMY_DIGEST)) do
      assert_not YAML.safe_load(render_deploy_yml).dig("env", "clear").key?("HOUSE_SOURCE_REPO")
    end
    with_env(example_env.merge("HOUSE_EMBEDDINGS_DIGEST" => DUMMY_DIGEST, "HOUSE_SOURCE_REPO" => "someone/souls-house")) do
      assert_equal "someone/souls-house", YAML.safe_load(render_deploy_yml).dig("env", "clear", "HOUSE_SOURCE_REPO")
    end
  end

  test "rendering with a malformed embeddings digest raises" do
    with_env(example_env.merge("HOUSE_EMBEDDINGS_DIGEST" => "latest")) do
      error = assert_raises(RuntimeError) { render_deploy_yml }
      assert_includes error.message, "HOUSE_EMBEDDINGS_DIGEST"
      assert_includes error.message, "sha256:"
    end
  end

  test "House.parse handles comments, blank lines, and quotes" do
    text = <<~ENV
      # a comment
      HOUSE_DOMAIN=house.example.org

      HOUSE_SITE_NAME="Quoted House"
      HOUSE_MAIL_FROM='Single Quoted <hello@house.example.org>'
      HOUSE_TRANSITION_ALIASES=
    ENV

    parsed = House.parse(text)

    assert_equal({
      "HOUSE_DOMAIN" => "house.example.org",
      "HOUSE_SITE_NAME" => "Quoted House",
      "HOUSE_MAIL_FROM" => "Single Quoted <hello@house.example.org>",
      "HOUSE_TRANSITION_ALIASES" => ""
    }, parsed)
  end

  test ".kamal/secrets resolves every secret through bin/house, never $(cat ...)" do
    secrets = File.read(Rails.root.join(".kamal/secrets"))
    assert_not_includes secrets, "$(cat "
  end

  # The WhatsApp connector is off until an installation turns it on: master
  # auto-deploys, and a deploy.yml that demanded its secrets would fail every
  # deploy before the accessory exists.
  test "the WhatsApp connector is absent unless HOUSE_COMMS_WHATSAPP_IMAGE is set" do
    with_env(example_env.merge("HOUSE_EMBEDDINGS_DIGEST" => DUMMY_DIGEST)) do
      config = YAML.safe_load(render_deploy_yml)
      assert_not config.fetch("accessories").key?("comms-whatsapp")
      assert_not config.fetch("env").fetch("clear").key?("COMMS_WHATSAPP_CONNECTOR_URL")
      assert_not_includes config.fetch("env").fetch("secret"), "COMMS_COMMAND_KEY"
    end
  end

  test "turning the WhatsApp connector on wires Rails and the accessory together" do
    comms = { "HOUSE_COMMS_WHATSAPP_IMAGE" => "registry.example/comms", "HOUSE_COMMS_WHATSAPP_DIGEST" => DUMMY_DIGEST,
              "HOUSE_COMMS_TLS_DIR" => "/srv/comms-tls" }
    with_env(example_env.merge("HOUSE_EMBEDDINGS_DIGEST" => DUMMY_DIGEST).merge(comms)) do
      config = YAML.safe_load(render_deploy_yml)
      accessory = config.fetch("accessories").fetch("comms-whatsapp")
      assert_equal "registry.example/comms@#{DUMMY_DIGEST}", accessory.fetch("image")
      assert_includes accessory.fetch("volumes"), "comms:/data"
      assert_equal "core=0", accessory.fetch("options").fetch("ulimit")
      assert_equal %w[COMMS_STORE_KEY:COMMS_WHATSAPP_STORE_KEY COMMS_COMMAND_KEY], accessory.fetch("env").fetch("secret")
      assert_equal "rails", accessory.dig("env", "clear", "COMMS_TLS_CLIENT_NAME")

      runtime = config.fetch("env")
      assert_equal "https://souls-house-comms-whatsapp:8443", runtime.dig("clear", "COMMS_WHATSAPP_CONNECTOR_URL")
      assert_includes runtime.fetch("secret"), "COMMS_COMMAND_KEY"
      # Everything the catalog requires before it offers WhatsApp is supplied.
      supplied = runtime.fetch("clear").keys + runtime.fetch("secret")
      assert_empty CommsConnector::WHATSAPP_ENV - supplied
      %w[web jobs].each do |role|
        assert_includes config.dig("servers", role, "options", "volume"), "/srv/comms-tls:/rails/comms-tls:ro"
      end
    end
    with_env(example_env.merge("HOUSE_EMBEDDINGS_DIGEST" => DUMMY_DIGEST).merge(comms).merge("HOUSE_COMMS_WHATSAPP_DIGEST" => "latest")) do
      assert_raises(RuntimeError) { render_deploy_yml }
    end
  end

  test "the Telegram connector is absent unless HOUSE_COMMS_TELEGRAM_IMAGE is set" do
    with_env(example_env.merge("HOUSE_EMBEDDINGS_DIGEST" => DUMMY_DIGEST)) do
      config = YAML.safe_load(render_deploy_yml)
      assert_not config.fetch("accessories").key?("comms-telegram")
      assert_not config.fetch("env").fetch("clear").key?("COMMS_CONNECTOR_URL")
    end
  end

  test "turning the Telegram connector on wires Rails and its own accessory together" do
    comms = { "HOUSE_COMMS_TELEGRAM_IMAGE" => "registry.example/telegram", "HOUSE_COMMS_TELEGRAM_DIGEST" => DUMMY_DIGEST,
              "HOUSE_COMMS_TLS_DIR" => "/srv/comms-tls" }
    with_env(example_env.merge("HOUSE_EMBEDDINGS_DIGEST" => DUMMY_DIGEST).merge(comms)) do
      config = YAML.safe_load(render_deploy_yml)
      assert_not config.fetch("accessories").key?("comms-whatsapp")
      accessory = config.fetch("accessories").fetch("comms-telegram")
      assert_equal "registry.example/telegram@#{DUMMY_DIGEST}", accessory.fetch("image")
      assert_includes accessory.fetch("volumes"), "comms_telegram:/data"
      assert_includes accessory.fetch("volumes"), "/srv/comms-tls:/tls:ro"
      assert_equal "core=0", accessory.fetch("options").fetch("ulimit")
      assert_equal true, accessory.fetch("options").fetch("read-only")
      assert_equal %w[COMMS_STORE_KEY COMMS_COMMAND_KEY TELEGRAM_API_ID TELEGRAM_API_HASH], accessory.fetch("env").fetch("secret")
      assert_equal "rails", accessory.dig("env", "clear", "COMMS_TLS_CLIENT_NAME")
      assert_equal "/tls/telegram.pem", accessory.dig("env", "clear", "COMMS_TLS_CERT")

      runtime = config.fetch("env")
      assert_equal "https://souls-house-comms-telegram:8443", runtime.dig("clear", "COMMS_CONNECTOR_URL")
      assert_not runtime.fetch("clear").key?("COMMS_WHATSAPP_CONNECTOR_URL")
      supplied = runtime.fetch("clear").keys + runtime.fetch("secret")
      assert_empty CommsConnector::TELEGRAM_ENV - supplied, "everything the catalog requires before it offers Telegram"
      %w[web jobs].each do |role|
        assert_includes config.dig("servers", role, "options", "volume"), "/srv/comms-tls:/rails/comms-tls:ro"
      end
    end
    both = comms.merge("HOUSE_COMMS_WHATSAPP_IMAGE" => "registry.example/comms", "HOUSE_COMMS_WHATSAPP_DIGEST" => DUMMY_DIGEST)
    with_env(example_env.merge("HOUSE_EMBEDDINGS_DIGEST" => DUMMY_DIGEST).merge(both)) do
      config = YAML.safe_load(render_deploy_yml)
      assert config.fetch("accessories").key?("comms-whatsapp")
      assert config.fetch("accessories").key?("comms-telegram")
      assert_equal 1, config.dig("servers", "web", "options", "volume").count("/srv/comms-tls:/rails/comms-tls:ro")
      assert_equal 1, config.fetch("env").fetch("secret").count("COMMS_COMMAND_KEY")
    end
    with_env(example_env.merge("HOUSE_EMBEDDINGS_DIGEST" => DUMMY_DIGEST).merge(comms).merge("HOUSE_COMMS_TELEGRAM_DIGEST" => "latest")) do
      assert_raises(RuntimeError) { render_deploy_yml }
    end
  end

  test "the voice embeddings service is absent unless HOUSE_VOICE_EMBEDDINGS_IMAGE is set" do
    with_env(example_env.merge("HOUSE_EMBEDDINGS_DIGEST" => DUMMY_DIGEST)) do
      config = YAML.safe_load(render_deploy_yml)
      assert_not config.fetch("accessories").key?("voice-embeddings")
      assert_not config.fetch("env").fetch("clear").key?("VOICE_EMBEDDING_URL")
      assert_not_includes config.fetch("env").fetch("secret"), "VOICE_EMBEDDING_TOKEN"
    end
  end

  test "turning voice embeddings on wires Rails and a private, read-only accessory together" do
    voice = { "HOUSE_VOICE_EMBEDDINGS_IMAGE" => "registry.example/voice", "HOUSE_VOICE_EMBEDDINGS_DIGEST" => DUMMY_DIGEST }
    with_env(example_env.merge("HOUSE_EMBEDDINGS_DIGEST" => DUMMY_DIGEST).merge(voice)) do
      config = YAML.safe_load(render_deploy_yml)
      accessory = config.fetch("accessories").fetch("voice-embeddings")
      assert_equal "registry.example/voice@#{DUMMY_DIGEST}", accessory.fetch("image")
      assert_equal "2g", accessory.fetch("options").fetch("memory")
      assert_equal 2, accessory.fetch("options").fetch("cpus")
      assert_equal [ "VOICE_EMBEDDING_TOKEN" ], accessory.fetch("env").fetch("secret")
      assert_equal true, accessory.fetch("options").fetch("read-only")
      assert_equal "core=0", accessory.fetch("options").fetch("ulimit")
      assert_not accessory.key?("port"), "no public port"
      runtime = config.fetch("env")
      assert_equal "http://souls-house-voice-embeddings:8080", runtime.dig("clear", "VOICE_EMBEDDING_URL")
      assert_equal 1, runtime.fetch("secret").count("VOICE_EMBEDDING_TOKEN")
    end
    with_env(example_env.merge("HOUSE_EMBEDDINGS_DIGEST" => DUMMY_DIGEST).merge(voice).merge("HOUSE_VOICE_EMBEDDINGS_DIGEST" => "latest")) do
      assert_raises(RuntimeError) { render_deploy_yml }
    end
  end

  private

  def render_deploy_yml
    ERB.new(File.read(Rails.root.join("config/deploy.yml")), trim_mode: "-").result
  end

  def example_env
    House.parse(File.read(Rails.root.join("config/house.env.example")))
  end

  def with_env(overrides)
    keys = (overrides.keys + %w[HOUSE_DOMAIN HOUSE_HOST HOUSE_EMBEDDINGS_DIGEST MNEMODYNE_EMBEDDING_IMAGE_DIGEST]).uniq
    previous = keys.index_with { |key| ENV[key] }
    keys.each { |key| ENV.delete(key) }
    overrides.each { |key, value| ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

end
