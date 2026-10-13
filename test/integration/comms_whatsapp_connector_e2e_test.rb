require "test_helper"
require "capybara"
require "openssl"
require "tmpdir"

# Rails and the real Go connector binary (services/comms-connector) talking
# to each other for real, with the synthetic provider in place of WhatsApp:
#
#   owner connects WhatsApp → Rails signs start_pairing with COMMS_COMMAND_KEY
#   and sends it over mutual TLS → the connector verifies it, takes the
#   callback secret, pushes QR codes, "pairs", and posts connected, chats and
#   messages to /internal/comms/connections/:id/events signed with that
#   secret → Rails verifies and stores them → the owner disconnects → Rails
#   sends unpair → the connector deletes the connection's store.
#
# Nothing is stubbed between the two sides. It needs the built binary, so it
# runs only when COMMS_CONNECTOR_BIN names one:
#
#   (cd services/comms-connector && make build)
#   COMMS_CONNECTOR_BIN=services/comms-connector/bin/comms-connector bin/rails test test/integration/comms_whatsapp_connector_e2e_test.rb
class CommsWhatsappConnectorE2eTest < ActionDispatch::IntegrationTest

  CANARY = "CANARY-COMMS-e2e-#{SecureRandom.hex(4)}".freeze

  setup do
    @bin = ENV["COMMS_CONNECTOR_BIN"].presence
    skip "set COMMS_CONNECTOR_BIN to the built connector to run the end-to-end test" unless @bin

    @bin = File.expand_path(@bin)
    @dir = Dir.mktmpdir("comms-e2e")
    @data = File.join(@dir, "data").tap { |path| Dir.mkdir(path) }
    @tls = write_tls(@dir)
    @command_key = SecureRandom.hex(32)

    # The connector posts its events to a real server running this app.
    @rails = Capybara::Server.new(Rails.application, port: free_port, host: "127.0.0.1").boot
    @connector_port = free_port
    @connector_log = File.join(@dir, "connector.log")
    @connector = spawn_connector
    wait_for_connector

    @env = ENV.to_h.slice(*CommsConnector::WHATSAPP_ENV)
    ENV["COMMS_WHATSAPP_CONNECTOR_URL"] = "https://127.0.0.1:#{@connector_port}"
    ENV["COMMS_COMMAND_KEY"] = @command_key
    ENV["COMMS_CONNECTOR_CLIENT_CERT"] = @tls[:client_cert]
    ENV["COMMS_CONNECTOR_CLIENT_KEY"] = @tls[:client_key]
    ENV["COMMS_CONNECTOR_CA_FILE"] = @tls[:ca]

    @account = accounts(:team)
    @owner = users(:admin)
  end

  teardown do
    if @connector
      Process.kill("TERM", @connector)
      Process.wait(@connector)
    end
    CommsConnector::WHATSAPP_ENV.each { |name| ENV[name] = @env[name] } if @env
    FileUtils.rm_rf(@dir) if @dir
  end

  test "pairing, messages and unpair between Rails and the real connector" do
    rails_log_start = File.size?(Rails.root.join("log/test.log")).to_i
    sign_in @owner

    post account_service_connections_path(@account), params: { provider: "whatsapp", management_scope: "personal" }
    connection = @account.service_connections.where(provider: "whatsapp").order(:id).last
    assert connection, "the connection was not created (start_pairing failed?)"

    wait_until("the connector to pair and deliver 15 messages") do
      connection.reload.status == "connected" && connection.comms_messages.count == 15
    end

    assert_equal 3, connection.comms_chats.count
    chat = connection.comms_chats.find_by!(provider_chat_id: "447700900000@s.whatsapp.net")
    assert_equal "Synthetic chat 0 #{CANARY}", chat.name
    assert_equal "direct", chat.kind
    message = chat.comms_messages.find_by!(provider_message_id: "SYN0000000")
    assert_equal "Synthetic message 0 in chat 0 #{CANARY}", message.body
    media = chat.comms_messages.find_by!(provider_message_id: "SYN0000001")
    assert_nil media.body
    assert_equal [ "image", "Synthetic caption #{CANARY}" ], [ media.media_kind, media.caption ]
    assert_equal "447700900000", connection.external_subject_id
    assert_nil connection.pairing_qr, "the QR is cleared once paired"
    assert_operator connection.comms_event_seq, :>=, 3, "events were delivered sequenced"
    assert Dir.exist?(File.join(@data, connection.public_id)), "the connector keeps a store per connection"

    delete account_service_connection_path(@account, connection.public_id)
    assert_equal "revoked", connection.reload.status
    assert_not Dir.exist?(File.join(@data, connection.public_id)), "unpair deletes the connection's store"

    # §3 log smoke test: the canary went through both sides and reached
    # neither log. (Rails filters body/caption/sender_name/chats; the
    # connector logs fixed words only.)
    connector_log = File.read(@connector_log)
    assert_includes connector_log, "start_pairing", "connector log captured"
    assert_not_includes connector_log, CANARY
    assert_not_includes connector_log, connection.public_id
    rails_log = File.binread(Rails.root.join("log/test.log"), nil, rails_log_start).to_s
    assert_not_includes rails_log, CANARY
  end

  # Mira's review, findings 1 and 2, through the real binary. Restarting
  # pairing is a new attempt: the connector resets the store and pairs again
  # under attempt 2, and Rails accepts only that. Then a disconnect the
  # connector never receives: Rails keeps the connection revoked and pending;
  # the connector's next event is answered 410, so it deletes the store
  # itself; the retry job's unpair then succeeds and clears the mark.
  test "a restart pairs as a new attempt, and a disconnect the connector missed is reconciled" do
    sign_in @owner
    post account_service_connections_path(@account), params: { provider: "whatsapp", management_scope: "personal" }
    connection = @account.service_connections.where(provider: "whatsapp").order(:id).last
    wait_until("the first pairing") { connection.reload.status == "connected" && connection.comms_messages.count == 15 }
    first_seq = connection.comms_event_seq

    connection.update_columns(status: "error")
    post restart_account_service_connection_pairing_path(@account, connection.public_id)
    assert_response :ok
    assert_equal 2, connection.reload.pairing_attempt
    wait_until("the second attempt to pair") { connection.reload.status == "connected" && connection.comms_event_seq > first_seq }
    assert_equal 15, connection.comms_messages.count

    store = File.join(@data, connection.public_id)
    ENV["COMMS_WHATSAPP_CONNECTOR_URL"] = "https://127.0.0.1:#{free_port}" # the unpair goes nowhere
    delete account_service_connection_path(@account, connection.public_id)
    connection.reload
    assert_equal "revoked", connection.status
    assert connection.unpair_pending?
    assert Dir.exist?(store), "the connector never heard of the disconnect"

    # The connector restarts; its resumed session posts, Rails answers 410.
    Process.kill("TERM", @connector)
    Process.wait(@connector)
    @connector = spawn_connector
    wait_for_connector
    wait_until("the connector to delete the revoked connection's store") { !Dir.exist?(store) }

    ENV["COMMS_WHATSAPP_CONNECTOR_URL"] = "https://127.0.0.1:#{@connector_port}"
    CommsUnpairJob.perform_now
    connection.reload
    assert_not connection.unpair_pending?
    assert_equal "revoked", connection.status
  end

  test "the connector refuses a command not signed with the command key" do
    connection = whatsapp_connection
    ENV["COMMS_COMMAND_KEY"] = SecureRandom.hex(32)
    error = assert_raises(CommsConnector::Error) { CommsConnector.start_pairing(connection) }
    assert_includes error.message, "401"
    assert_not Dir.exist?(File.join(@data, connection.public_id))
  end

  test "the connector refuses Rails without the house client certificate" do
    connection = whatsapp_connection
    other = write_tls(File.join(@dir, "other").tap { |path| Dir.mkdir(path) })
    ENV["COMMS_CONNECTOR_CLIENT_CERT"] = other[:client_cert]
    ENV["COMMS_CONNECTOR_CLIENT_KEY"] = other[:client_key]
    assert_raises(OpenSSL::SSL::SSLError, Errno::ECONNRESET, EOFError) { CommsConnector.start_pairing(connection) }
    assert_not Dir.exist?(File.join(@data, connection.public_id))
  end

  private

  def whatsapp_connection
    attributes = Services::Definition.fetch("whatsapp").adapter.connection_attributes(credentials: {}, user: @owner)
    @account.service_connections.create!(
      connected_by_user: @owner, provider: "whatsapp", management_scope: "personal", status: "pairing",
      **attributes.slice(:label, :credential_kind, :credential_fingerprint, :credential_metadata)
        .merge(credential_payload_hash: attributes[:credential_payload])
    )
  end

  def spawn_connector
    env = {
      "COMMS_STORE_KEY" => (@store_key ||= Base64.strict_encode64(SecureRandom.bytes(32))),
      "COMMS_COMMAND_KEY" => @command_key,
      "COMMS_RAILS_URL" => "http://127.0.0.1:#{@rails.port}",
      "COMMS_TLS_CERT" => @tls[:server_cert], "COMMS_TLS_KEY" => @tls[:server_key],
      "COMMS_TLS_CLIENT_CA" => @tls[:ca], "COMMS_TLS_CLIENT_NAME" => "rails",
      "COMMS_LISTEN" => "127.0.0.1:#{@connector_port}", "COMMS_DATA_DIR" => @data,
      "COMMS_PROVIDER" => "synthetic", "COMMS_ALLOW_SYNTHETIC" => "1", "COMMS_SYNTHETIC_MARKER" => CANARY,
      "GOTRACEBACK" => "none"
    }
    Process.spawn(env, @bin, unsetenv_others: true, out: @connector_log, err: @connector_log)
  end

  def wait_for_connector
    wait_until("the connector to listen") do
      Socket.tcp("127.0.0.1", @connector_port, connect_timeout: 0.2) { true }
    rescue SystemCallError
      false
    end
  end

  def wait_until(what, timeout: 20)
    deadline = Time.now + timeout
    until yield
      flunk "timed out waiting for #{what}; connector log:\n#{File.read(@connector_log)}" if Time.now > deadline
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
    end
    server_key = OpenSSL::PKey::EC.generate("prime256v1")
    server = certificate("/CN=souls-house-comms-whatsapp", server_key, ca, ca_key) do |cert, ext|
      cert.add_extension(ext.create_extension("subjectAltName", "IP:127.0.0.1"))
      cert.add_extension(ext.create_extension("extendedKeyUsage", "serverAuth"))
    end
    client_key = OpenSSL::PKey::EC.generate("prime256v1")
    client = certificate("/CN=rails", client_key, ca, ca_key) do |cert, ext|
      cert.add_extension(ext.create_extension("extendedKeyUsage", "clientAuth"))
    end
    files = { ca: [ ca ], server_cert: [ server ], server_key: [ server_key ], client_cert: [ client ], client_key: [ client_key ] }
    files.to_h do |name, (object)|
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
