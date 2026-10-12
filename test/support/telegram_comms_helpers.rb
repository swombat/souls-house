require "tmpdir"
require "openssl"

# Shared setup for the Telegram comms tests: a connection made the way the
# integrations page makes one, signed connector events, and a fake connector
# that records commands and answers with canned JSON.
module TelegramCommsHelpers

  def telegram_connection(account:, user:, status: "connected", generation: 1)
    attributes = Services::Definition.fetch("telegram").adapter.connection_attributes(credentials: {}, user: user)
    account.service_connections.create!(
      connected_by_user: user, provider: "telegram", management_scope: "personal", status: status,
      login_generation: generation,
      **attributes.slice(:label, :credential_kind, :credential_fingerprint, :credential_metadata)
        .merge(credential_payload_hash: attributes[:credential_payload])
    )
  end

  def telegram_events_path(connection)
    Rails.application.routes.url_helpers.internal_comms_connection_events_path(connection.public_id)
  end

  def post_telegram_event(connection, event)
    body = JSON.generate(event)
    headers = CommsSignature.headers_for(
      secret: connection.credential_payload_hash.fetch("callback_secret"), connection_id: connection.public_id,
      method: "POST", path: telegram_events_path(connection), body: body
    ).merge("Content-Type" => "application/json")
    post telegram_events_path(connection), params: body, headers: headers
  end

  TLS_ENV = %w[COMMS_CONNECTOR_CLIENT_CERT COMMS_CONNECTOR_CLIENT_KEY COMMS_CONNECTOR_CA_FILE].freeze

  # Fake mutual-TLS material: a throwaway CA and a client certificate it
  # signed, written once per process.
  def self.tls_files
    @tls_files ||= begin
      dir = Dir.mktmpdir("comms-tls")
      ca_key = OpenSSL::PKey::RSA.new(2048)
      ca = OpenSSL::X509::Certificate.new
      ca.version = 2
      ca.serial = 1
      ca.subject = ca.issuer = OpenSSL::X509::Name.parse("/CN=house test CA")
      ca.public_key = ca_key.public_key
      ca.not_before = Time.now - 60
      ca.not_after = Time.now + 3600
      ca.sign(ca_key, OpenSSL::Digest.new("SHA256"))
      key = OpenSSL::PKey::RSA.new(2048)
      cert = OpenSSL::X509::Certificate.new
      cert.version = 2
      cert.serial = 2
      cert.subject = OpenSSL::X509::Name.parse("/CN=rails")
      cert.issuer = ca.subject
      cert.public_key = key.public_key
      cert.not_before = Time.now - 60
      cert.not_after = Time.now + 3600
      cert.sign(ca_key, OpenSSL::Digest.new("SHA256"))
      paths = { "COMMS_CONNECTOR_CA_FILE" => "ca.pem", "COMMS_CONNECTOR_CLIENT_CERT" => "client.pem", "COMMS_CONNECTOR_CLIENT_KEY" => "client.key" }
        .transform_values { |name| File.join(dir, name) }
      File.write(paths["COMMS_CONNECTOR_CA_FILE"], ca.to_pem)
      File.write(paths["COMMS_CONNECTOR_CLIENT_CERT"], cert.to_pem)
      File.write(paths["COMMS_CONNECTOR_CLIENT_KEY"], key.to_pem)
      paths
    end
  end

  # tls: the mutual-TLS settings to present (all of them by default; pass a
  # subset to test a missing one).
  def with_telegram_connector(url: "https://comms.internal:8443", key: "test-command-key", replies: {}, tls: TLS_ENV)
    requests = []
    previous = ENV.to_h.slice("COMMS_CONNECTOR_URL", "COMMS_COMMAND_KEY", *TLS_ENV)
    ENV["COMMS_CONNECTOR_URL"] = url
    ENV["COMMS_COMMAND_KEY"] = key
    TLS_ENV.each { |name| ENV[name] = tls.include?(name) ? TelegramCommsHelpers.tls_files.fetch(name) : nil }
    fake = Object.new
    fake.define_singleton_method(:request) do |request|
      requests << request
      operation = request.path.split("/").last
      reply = replies.fetch(operation, {})
      raise reply if reply.is_a?(Class) && reply <= Exception

      status, body = reply.is_a?(Array) ? reply : [ 200, reply ]
      klass = Net::HTTPResponse::CODE_TO_OBJ[status.to_s]
      klass.new("1.1", status.to_s, "").tap do |response|
        response.instance_variable_set(:@read, true)
        response.instance_variable_set(:@body, JSON.generate(body))
      end
    end
    options_seen = []
    Net::HTTP.stub(:start, ->(_host, _port, **options, &block) { options_seen << options; block.call(fake) }) do
      yield requests, options_seen
    end
  ensure
    [ "COMMS_CONNECTOR_URL", "COMMS_COMMAND_KEY", *TLS_ENV ].each { |name| ENV[name] = previous[name] }
  end

end
