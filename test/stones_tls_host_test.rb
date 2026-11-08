require "minitest/autorun"
require "tmpdir"
require_relative "../ops/deploy/stones-tls"

class StonesTlsHostTest < Minitest::Test

  DOMAIN = "example.test"

  def setup
    @dir = Dir.mktmpdir
    @secrets = "#{@dir}/secrets"
    @lock = "#{@dir}/deployment.lock"
    @root_key = OpenSSL::PKey::EC.generate("prime256v1")
    @root = certificate(@root_key, ca: true)
    @store = OpenSSL::X509::Store.new
    @store.add_cert(@root)
    @tls = StonesTls.new(secrets: @secrets, lock: @lock, store: @store)
    @key = OpenSSL::PKey::EC.generate("prime256v1")
    @leaf = certificate(@key)
    @pair = pair(@leaf, @key)
    @chain_path = write("fullchain", @pair[StonesTls::CERT])
    @key_path = write("key", @pair[StonesTls::KEY])
    @unrelated = "# keep this\nTOKEN='secret\nSTONES_TLS_PRIVATE_KEY_PEM=not-an-entry'\nOTHER=value\n"
    write("secrets", @unrelated)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def certificate(key, ca: false, wildcard: true, before: Time.now - 60, after: Time.now + 90 * 86_400)
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = OpenSSL::BN.rand(128).to_i
    cert.subject = OpenSSL::X509::Name.parse(ca ? "/CN=Test Root" : "/CN=ignored.example.test")
    cert.issuer = ca ? cert.subject : @root.subject
    cert.public_key = key
    cert.not_before, cert.not_after = before, after
    factory = OpenSSL::X509::ExtensionFactory.new
    factory.subject_certificate = cert
    factory.issuer_certificate = ca ? cert : @root
    cert.add_extension(factory.create_extension("basicConstraints", ca ? "CA:TRUE" : "CA:FALSE", true))
    cert.add_extension(factory.create_extension("keyUsage", ca ? "keyCertSign,cRLSign" : "digitalSignature", true))
    cert.add_extension(factory.create_extension("subjectAltName", wildcard ? "DNS:*.#{DOMAIN}" : "DNS:single.#{DOMAIN}")) unless ca
    cert.sign(ca ? key : @root_key, "SHA256")
    cert
  end

  def pair(cert, key)
    { StonesTls::CERT => cert.to_pem, StonesTls::KEY => key.private_to_pem }
  end

  def write(name, content)
    path = "#{@dir}/#{name}"
    File.write(path, content)
    File.chmod(0o600, path)
    path
  end

  def install
    @tls.install(fullchain: @chain_path, key: @key_path, domain: DOMAIN)
  end

  def substitute(object, name, implementation)
    original = object.method(name)
    object.define_singleton_method(name, implementation)
    yield
  ensure
    object.define_singleton_method(name, original)
  end

  def test_install_preserves_unrelated_multiline_and_installs_pair_together
    assert_equal :installed, install
    assert File.binread(@secrets).start_with?(@unrelated)
    assert_equal @pair, @tls.pair_from(@tls.entries(File.binread(@secrets)))
    assert_equal 0o600, File.stat(@secrets).mode & 0o777
    assert_empty Dir.glob("#{@dir}/.stones-tls-*")
  end

  def test_backup_and_idempotence
    old_key = OpenSSL::PKey::EC.generate("prime256v1")
    old = pair(certificate(old_key), old_key)
    File.write(@secrets, @unrelated + @tls.render(old))
    install
    backup = "#{@secrets}.stones-previous"
    assert_equal @tls.render(old), File.read(backup)
    assert_equal 0o600, File.stat(backup).mode & 0o777
    assert_equal :unchanged, install
    assert_equal @tls.render(old), File.read(backup)
  end

  def test_preflight_changes_no_files
    assert_equal :validated, @tls.install(fullchain: @chain_path, key: @key_path, domain: DOMAIN, dry_run: true)
    assert_equal @unrelated, File.read(@secrets)
    refute File.exist?("#{@secrets}.stones-previous")
  end

  def test_pem_without_final_newline_and_unrelated_unterminated_last_line
    @pair = @pair.transform_values(&:chomp)
    write("fullchain", @pair.fetch(StonesTls::CERT))
    write("key", @pair.fetch(StonesTls::KEY))
    write("secrets", "TOKEN=keep")
    assert_equal :installed, install
    assert File.read(@secrets).start_with?("TOKEN=keep\n")
    assert_equal @pair, @tls.pair_from(@tls.entries(File.binread(@secrets)))
  end

  def test_rejects_mismatch_and_does_not_change_secrets
    write("key", OpenSSL::PKey::EC.generate("prime256v1").private_to_pem)
    assert_raises(StonesTls::Invalid) { install }
    assert_equal @unrelated, File.read(@secrets)
    refute File.exist?("#{@secrets}.stones-previous")
  end

  def test_rejects_missing_wildcard_expired_future_and_near_expiry
    [
      certificate(@key, wildcard: false),
      certificate(@key, before: Time.now - 200, after: Time.now - 100),
      certificate(@key, before: Time.now + 100),
      certificate(@key, after: Time.now + 3600)
    ].each do |cert|
      assert_raises(StonesTls::Invalid) { @tls.validate(pair(cert, @key), domain: DOMAIN) }
    end
  end

  def test_rejects_untrusted_chain_and_malformed_extra_pem
    other = StonesTls.new(secrets: @secrets, lock: @lock, store: OpenSSL::X509::Store.new)
    assert_raises(StonesTls::Invalid) { other.validate(@pair, domain: DOMAIN) }
    assert_raises(StonesTls::Invalid) { @tls.validate(@pair.merge(StonesTls::CERT => @leaf.to_pem + "garbage"), domain: DOMAIN) }
    assert_raises(StonesTls::Invalid) { @tls.validate(@pair.merge(StonesTls::KEY => @key.public_to_pem), domain: DOMAIN) }
    encrypted = @key.private_to_pem(OpenSSL::Cipher.new("aes-256-cbc"), "password")
    assert_raises(StonesTls::Invalid) { @tls.validate(@pair.merge(StonesTls::KEY => encrypted), domain: DOMAIN) }
  end

  def test_does_not_block_or_modify_when_deployment_lock_held
    File.open(@lock, "a") do |lock|
      lock.flock(File::LOCK_EX)
      assert_raises(StonesTls::Invalid) { install }
    end
    assert_equal @unrelated, File.read(@secrets)
  end

  def test_refuses_duplicate_partial_or_unsupported_secrets_without_changes
    [
      @tls.render(@pair) * 2,
      "#{StonesTls::CERT}='partial'\n",
      "BROKEN='unterminated\n",
      "BROKEN='closed' not-an-entry\n"
    ].each do |bad|
      original = @unrelated + bad
      File.write(@secrets, original)
      assert_raises(StonesTls::Invalid) { install }
      assert_equal original, File.read(@secrets)
    end
  end

  def test_refuses_symlink_and_world_readable_input
    File.chmod(0o644, @key_path)
    assert_raises(StonesTls::Invalid) { install }
    File.chmod(0o600, @key_path)
    File.rename(@key_path, "#{@dir}/real-key")
    File.symlink("#{@dir}/real-key", @key_path)
    assert_raises(StonesTls::Invalid) { install }
  end

  def test_prepare_secures_acme_fullchain_after_each_rewrite
    2.times do
      File.chmod(0o644, @chain_path)
      @tls.prepare_inputs([ @chain_path, @key_path ])
      assert_equal 0o600, File.stat(@chain_path).mode & 0o777
      assert_equal 0o600, File.stat(@key_path).mode & 0o777
      assert_includes [ :installed, :unchanged ], install
    end
  end

  def test_prepare_refuses_symlinks_and_nonregular_files
    target = write("other", "not a certificate")
    File.chmod(0o644, target)
    link = "#{@dir}/link"
    File.symlink(target, link)
    assert_raises(Errno::ELOOP) { @tls.prepare_inputs([ link ]) }
    assert_equal 0o644, File.stat(target).mode & 0o777
    assert_raises(StonesTls::Invalid) { @tls.prepare_inputs([ @dir ]) }
  end

  def test_failed_final_replace_leaves_previous_pair
    old_key = OpenSSL::PKey::EC.generate("prime256v1")
    old = pair(certificate(old_key), old_key)
    original = @unrelated + @tls.render(old)
    File.write(@secrets, original)
    rename = File.method(:rename)
    secrets = @secrets
    substitute(File, :rename, ->(source, target) { target == secrets ? raise(IOError) : rename.call(source, target) }) do
      assert_raises(IOError) { install }
    end
    assert_equal original, File.read(@secrets)
    assert_equal @tls.render(old), File.read("#{@secrets}.stones-previous")
  end

  def with_live_certificate(cert, key)
    listener = TCPServer.new("127.0.0.1", 0)
    port = listener.addr[1]
    context = OpenSSL::SSL::SSLContext.new
    context.cert, context.key = cert, key
    server = OpenSSL::SSL::SSLServer.new(listener, context)
    thread = Thread.new { server.accept.close }
    connect = Socket.method(:tcp)
    substitute(Socket, :tcp, ->(_host, _port, **options, &block) { connect.call("127.0.0.1", port, **options, &block) }) do
      yield
    end
  ensure
    listener&.close
    thread&.join
  end

  def test_check_verifies_served_pair_and_reports_pending_refresh
    install
    with_live_certificate(@leaf, @key) do
      assert_equal :healthy, @tls.check(domain: DOMAIN, host: "probe.#{DOMAIN}")
    end
    old = certificate(@key)
    with_live_certificate(old, @key) do
      error = assert_raises(StonesTls::Invalid) { @tls.check(domain: DOMAIN, host: "probe.#{DOMAIN}") }
      assert_includes error.message, "manual Deploy Rails required"
    end
  end

  def test_check_alerts_on_expiry_even_before_connection
    write("secrets", @tls.render(pair(certificate(@key, after: Time.now + 10 * 86_400), @key)))
    assert_raises(StonesTls::Invalid) { @tls.check(domain: DOMAIN, host: "probe.#{DOMAIN}") }
  end

end
