require "test_helper"
require "capybara"
require "openssl"
require "tmpdir"

# Rails and the real Telegram connector process (services/telegram-connector,
# python -m connector) talking to each other for real, with the connector's
# fake Telegram (TELEGRAM_PROVIDER=fake) in place of Telegram:
#
#   the owner connects Telegram → Rails signs start_login with
#   COMMS_COMMAND_KEY and sends it over mutual TLS → the connector verifies
#   it, takes the callback secret, posts login QR codes, the fake "scans" one,
#   asks for the two-step password → the owner submits it through Rails →
#   the connector signs in, posts connected, chats, 30 days of history and
#   live messages to /internal/comms/connections/:id/events → two residents
#   the owner granted read them (a third, ungranted, cannot) → the connector
#   restarts and new messages keep arriving → search → the owner disconnects
#   → Rails sends logout → the connector logs out at "Telegram" and deletes
#   the connection's store.
#
# Nothing is stubbed between Rails and the connector. It needs a Python with
# the connector's requirements, so it runs only when
# COMMS_TELEGRAM_CONNECTOR_PYTHON names one:
#
#   COMMS_TELEGRAM_CONNECTOR_PYTHON=/path/to/venv/bin/python \
#     bin/rails test test/integration/comms_telegram_connector_e2e_test.rb
class CommsTelegramConnectorE2eTest < ActionDispatch::IntegrationTest

  CANARY = "CANARY-TG-e2e-#{SecureRandom.hex(4)}".freeze
  PASSWORD = "PASSWORD-CANARY-#{SecureRandom.hex(4)}".freeze
  LIVE = 12
  SERVICE_DIR = Rails.root.join("services/telegram-connector").to_s
  RAILS_ENV_NAMES = %w[COMMS_CONNECTOR_URL COMMS_COMMAND_KEY COMMS_CONNECTOR_CLIENT_CERT
                       COMMS_CONNECTOR_CLIENT_KEY COMMS_CONNECTOR_CA_FILE].freeze

  setup do
    @python = ENV["COMMS_TELEGRAM_CONNECTOR_PYTHON"].presence
    skip "set COMMS_TELEGRAM_CONNECTOR_PYTHON to a Python with the connector's requirements" unless @python

    @dir = Dir.mktmpdir("tg-e2e")
    @data = File.join(@dir, "data").tap { |path| Dir.mkdir(path) }
    @telegram = File.join(@dir, "telegram")
    @tls = write_tls(@dir)
    @command_key = SecureRandom.hex(32)
    @rails = Capybara::Server.new(Rails.application, port: free_port, host: "127.0.0.1").boot
    @connector_port = free_port
    @connector_log = File.join(@dir, "connector.log")
    @connector = spawn_connector
    wait_for_connector

    @env = ENV.to_h.slice(*RAILS_ENV_NAMES)
    ENV["COMMS_CONNECTOR_URL"] = "https://127.0.0.1:#{@connector_port}"
    ENV["COMMS_COMMAND_KEY"] = @command_key
    ENV["COMMS_CONNECTOR_CLIENT_CERT"] = @tls[:client_cert]
    ENV["COMMS_CONNECTOR_CLIENT_KEY"] = @tls[:client_key]
    ENV["COMMS_CONNECTOR_CA_FILE"] = @tls[:ca]

    @owner = users(:user_1)
    @account = accounts(:personal_account)
    @lume = agents(:research_assistant)
    @mira = agents(:code_reviewer)
  end

  teardown do
    stop_connector if @connector
    RAILS_ENV_NAMES.each { |name| ENV[name] = @env[name] } if @env
    FileUtils.rm_rf(@dir) if @dir
  end

  test "Daniel connects, both residents read a permitted chat, and new messages keep arriving" do
    rails_log_start = File.size?(Rails.root.join("log/test.log")).to_i
    sign_in @owner

    post account_service_connections_path(@account), params: { provider: "telegram", management_scope: "personal" }
    connection = @account.service_connections.where(provider: "telegram").order(:id).last
    assert connection, "the connection was not created (start_login failed?)"
    assert_equal 1, connection.login_generation

    # QR, then the two-step password, through the owner's page.
    wait_until("the connector to ask for the password") { connection.reload.login_state["step"] == "password" }
    assert_equal "the usual", connection.login_state["hint"]
    post password_account_service_connection_login_path(@account, connection.public_id),
         params: { password: "wrong-#{PASSWORD}", generation: connection.login_generation }
    assert_equal "password_invalid", response.parsed_body["outcome"]
    post password_account_service_connection_login_path(@account, connection.public_id),
         params: { password: PASSWORD, generation: connection.login_generation }
    assert_equal "accepted", response.parsed_body["outcome"]

    wait_until("connected") { connection.reload.status == "connected" }
    assert_equal "1000", connection.external_subject_id
    assert_includes connection.external_identity, "@daniel"

    alice = nil
    wait_until("history and the first live messages") do
      alice = connection.comms_chats.find_by(provider_chat_id: "user:2001")
      alice && bodies(alice).count { |body| body.start_with?("old ") } == 29 && live_bodies(alice).size >= 2
    end
    assert_equal({ "synced" => false, "reason" => "bot" }, connection.comms_chats.find_by!(provider_chat_id: "user:2002").sync_state.slice("synced", "reason"))
    assert_equal "broadcast_channel", connection.comms_chats.find_by!(provider_chat_id: "channel:4002").sync_state["reason"]

    # The owner grants two residents; a third is not granted.
    [ @lume, @mira ].each do |agent|
      patch account_agent_service_access_path(@account, agent, connection.public_id), params: { enabled: true }
    end
    assert connection.agent_service_accesses.enabled.where(agent: [ @lume, @mira ]).count == 2
    other = @account.agents.where.not(id: [ @lume.id, @mira.id ]).first

    # The connector restarts; live messages keep arriving after it.
    before_restart = live_bodies(alice).size
    assert_operator before_restart, :<, LIVE, "some live messages are still to come"
    stop_connector
    @connector = spawn_connector
    wait_for_connector
    wait_until("every live message, across the restart", timeout: 40) { live_bodies(alice).size == LIVE }

    [ @lume, @mira ].each do |agent|
      key = ApiKey.generate_for(@owner, name: "comms e2e", agent: agent)
      headers = { "Authorization" => "Bearer #{key.raw_token}" }
      get api_v1_service_connection_comms_messages_url(connection.public_id, chat: "user:2001", limit: 100), headers: headers
      assert_response :ok
      bodies = response.parsed_body["messages"].map { |message| message["body"] }
      assert_equal (0...LIVE).map { |n| "live #{n}#{CANARY}" }, bodies.grep(/\Alive /), "#{agent.name} reads every live message once"

      get api_v1_service_connection_comms_search_url(connection.public_id, query: "live 3"), headers: headers
      assert_response :ok
      assert_equal [ "live 3#{CANARY}" ], response.parsed_body["results"].map { |result| result["body"] }
    end
    if other
      key = ApiKey.generate_for(@owner, name: "ungranted", agent: other)
      get api_v1_service_connection_comms_messages_url(connection.public_id, chat: "user:2001"),
          headers: { "Authorization" => "Bearer #{key.raw_token}" }
      assert_response :not_found
    end
    assert_operator connection.reload.comms_event_seq, :>=, 5

    # Disconnect: logout at Telegram, the connector's store row goes.
    delete account_service_connection_path(@account, connection.public_id)
    assert_equal "revoked", connection.reload.status
    world = JSON.parse(File.read(File.join(@telegram, "world.json")))
    assert_empty world["sessions"], "the session was logged out at Telegram"

    connector_log = File.read(@connector_log)
    assert_includes connector_log, "command done: op=logout"
    [ CANARY, PASSWORD, connection.public_id ].each { |secret| assert_not_includes connector_log, secret }
    rails_log = File.binread(Rails.root.join("log/test.log"), nil, rails_log_start).to_s
    assert_not_includes rails_log, PASSWORD
    Dir.glob(File.join(@data, "*")).each do |path|
      content = File.binread(path)
      assert_not_includes content, PASSWORD, path
      assert_not_includes content, CANARY, path
    end
  end

  test "the connector refuses a command not signed with the command key, and Rails without the house certificate" do
    connection = telegram_connection
    ENV["COMMS_COMMAND_KEY"] = SecureRandom.hex(32)
    error = assert_raises(CommsConnector::Error) do
      CommsConnector.telegram_command(connection, "start_login", generation: 1, callback_secret: "x" * 64, callback_secret_version: 1)
    end
    assert_includes error.message, "401"

    ENV["COMMS_COMMAND_KEY"] = @command_key
    other = write_tls(File.join(@dir, "other").tap { |path| Dir.mkdir(path) })
    ENV["COMMS_CONNECTOR_CLIENT_CERT"] = other[:client_cert]
    ENV["COMMS_CONNECTOR_CLIENT_KEY"] = other[:client_key]
    assert_raises(OpenSSL::SSL::SSLError, Errno::ECONNRESET, EOFError) do
      CommsConnector.telegram_command(connection, "logout")
    end
  end

  private

  # Bodies are encrypted (non-deterministically), so they are filtered here,
  # not in SQL.
  def bodies(chat)
    chat.comms_messages.reload.map(&:body).compact
  end

  def live_bodies(chat)
    bodies(chat).grep(/\Alive /)
  end

  def telegram_connection
    attributes = Services::Definition.fetch("telegram").adapter.connection_attributes(credentials: {}, user: @owner)
    @account.service_connections.create!(
      connected_by_user: @owner, provider: "telegram", management_scope: "personal", status: "pairing", login_generation: 1,
      **attributes.slice(:label, :credential_kind, :credential_fingerprint, :credential_metadata)
        .merge(credential_payload_hash: attributes[:credential_payload])
    )
  end

  def spawn_connector
    env = {
      "PATH" => ENV.fetch("PATH", ""), "PYTHONPATH" => SERVICE_DIR,
      "COMMS_STORE_KEY" => (@store_key ||= SecureRandom.hex(32)),
      "COMMS_COMMAND_KEY" => @command_key,
      "COMMS_RAILS_URL" => "http://127.0.0.1:#{@rails.port}",
      "COMMS_TLS_CERT" => @tls[:server_cert], "COMMS_TLS_KEY" => @tls[:server_key],
      "COMMS_TLS_CLIENT_CA" => @tls[:ca], "COMMS_TLS_CLIENT_NAME" => "rails",
      "COMMS_LISTEN" => "127.0.0.1:#{@connector_port}", "COMMS_DATA_DIR" => @data,
      "TELEGRAM_PROVIDER" => "fake", "COMMS_ALLOW_FAKE" => "1", "TELEGRAM_FAKE_DIR" => @telegram,
      "TELEGRAM_FAKE_MARKER" => CANARY, "TELEGRAM_FAKE_PASSWORD" => PASSWORD,
      "TELEGRAM_FAKE_LIVE" => LIVE.to_s, "TELEGRAM_FAKE_LIVE_INTERVAL" => "2"
    }
    Process.spawn(env, @python, "-m", "connector", chdir: SERVICE_DIR, unsetenv_others: true,
                                                   out: [ @connector_log, "a" ], err: [ @connector_log, "a" ])
  end

  def stop_connector
    Process.kill("TERM", @connector)
    Process.wait(@connector)
    @connector = nil
  end

  def wait_for_connector
    wait_until("the connector to listen") do
      Socket.tcp("127.0.0.1", @connector_port, connect_timeout: 0.2) { true }
    rescue SystemCallError
      false
    end
  end

  def wait_until(what, timeout: 30)
    deadline = Time.now + timeout
    until yield
      flunk "timed out waiting for #{what}; connector log:\n#{File.read(@connector_log).last(4000)}" if Time.now > deadline
      sleep 0.1
    end
  end

  def free_port
    server = TCPServer.new("127.0.0.1", 0)
    server.addr[1]
  ensure
    server&.close
  end

  # A throwaway house CA, the connector's server certificate (127.0.0.1) and
  # Rails's client certificate (CN=rails).
  def write_tls(dir)
    ca_key = OpenSSL::PKey::EC.generate("prime256v1")
    ca = certificate("/CN=house e2e CA", ca_key, nil, nil) do |cert, ext|
      cert.add_extension(ext.create_extension("basicConstraints", "CA:TRUE", true))
      cert.add_extension(ext.create_extension("keyUsage", "keyCertSign", true))
      cert.add_extension(ext.create_extension("subjectKeyIdentifier", "hash"))
    end
    server_key = OpenSSL::PKey::EC.generate("prime256v1")
    server = certificate("/CN=souls-house-comms-telegram", server_key, ca, ca_key) do |cert, ext|
      cert.add_extension(ext.create_extension("subjectAltName", "IP:127.0.0.1"))
      cert.add_extension(ext.create_extension("extendedKeyUsage", "serverAuth"))
      cert.add_extension(ext.create_extension("authorityKeyIdentifier", "keyid:always"))
    end
    client_key = OpenSSL::PKey::EC.generate("prime256v1")
    client = certificate("/CN=rails", client_key, ca, ca_key) do |cert, ext|
      cert.add_extension(ext.create_extension("extendedKeyUsage", "clientAuth"))
      cert.add_extension(ext.create_extension("authorityKeyIdentifier", "keyid:always"))
    end
    files = { ca: ca, server_cert: server, server_key: server_key, client_cert: client, client_key: client_key }
    files.to_h do |name, object|
      path = File.join(dir, "#{name}.pem")
      File.write(path, object.to_pem)
      [ name, path ]
    end
  end

  def certificate(subject, key, issuer, issuer_key)
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = SecureRandom.random_number(2**62)
    cert.subject = OpenSSL::X509::Name.parse(subject)
    cert.issuer = issuer ? issuer.subject : cert.subject
    cert.public_key = key
    cert.not_before = Time.now - 60
    cert.not_after = Time.now + 3600
    ext = OpenSSL::X509::ExtensionFactory.new
    ext.subject_certificate = cert
    ext.issuer_certificate = issuer || cert
    yield cert, ext
    cert.sign(issuer_key || key, OpenSSL::Digest.new("SHA256"))
    cert
  end

end
