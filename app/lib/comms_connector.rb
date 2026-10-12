require "net/http"

# Rails → comms connector commands, signed with the connection's callback
# secret exactly as the connector signs its events (CommsSignature). There are
# two commands and no send: start pairing, and unpair.
#
# COMMS_CONNECTOR_URL names the private-network connector. While it is unset
# (development, tests, and every deploy before the accessory exists) a
# command is not sent; the intent is logged and :not_configured returned.
module CommsConnector

  COMMANDS = %w[start_pairing unpair].freeze

  class Error < StandardError; end

  module_function

  def start_pairing(connection) = deliver(connection, "start_pairing")
  def unpair(connection) = deliver(connection, "unpair")

  # Telegram commands (proposal 2026-10-11 §5). Unlike WhatsApp's, some of
  # these carry secrets (the callback secret, a two-step password), so:
  #
  # - the connector must be reached over https with mutual TLS: Rails's
  #   client certificate and key (COMMS_CONNECTOR_CLIENT_CERT/_KEY) and the
  #   house CA that signed the connector's (COMMS_CONNECTOR_CA_FILE). Plain
  #   http, or any of the three missing, sends nothing;
  # - each command is signed with the connector-wide COMMS_COMMAND_KEY (its
  #   id in COMMS_COMMAND_KEY_ID), over the connection, operation, a unique
  #   command id, the issue time and the body, so the connector can reject
  #   stale or replayed commands and commands for another connection.
  #
  # Returns the connector's JSON reply as a Hash, or :not_configured.
  TELEGRAM_COMMANDS = %w[start_login submit_password cancel_login logout search].freeze

  def telegram_command(connection, operation, **fields)
    raise ArgumentError, "unknown telegram command #{operation}" unless TELEGRAM_COMMANDS.include?(operation)

    unless base_url
      Rails.logger.info("[comms] connector not configured; #{operation} intended for #{connection.public_id}")
      return :not_configured
    end

    uri = URI.join(base_url, "/connections/#{connection.public_id}/#{operation}")
    raise Error, "the comms connector must be reached over https" unless uri.scheme == "https"
    tls = tls_options

    issued_at = Time.current.to_i
    command_id = SecureRandom.hex(16)
    body = JSON.generate(fields.merge(connection: connection.public_id, operation:, command_id:, issued_at:))
    request = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "application/json"
    CommsCommandSignature.headers_for(
      connection_id: connection.public_id, operation:, command_id:, issued_at:, body:
    ).each { |name, value| request[name] = value }
    request.body = body

    response = Net::HTTP.start(uri.hostname, uri.port, **tls, open_timeout: 5, read_timeout: 30) do |http|
      http.request(request)
    end
    raise Error, "comms connector #{operation} failed (#{response.code})" unless response.is_a?(Net::HTTPSuccess)

    parsed = response.body.present? ? JSON.parse(response.body) : {}
    parsed.is_a?(Hash) ? parsed : {}
  rescue JSON::ParserError
    raise Error, "comms connector #{operation} returned invalid JSON"
  rescue CommsCommandSignature::MissingKey => e
    raise Error, e.message
  end

  TLS_SETTINGS = %w[COMMS_CONNECTOR_CLIENT_CERT COMMS_CONNECTOR_CLIENT_KEY COMMS_CONNECTOR_CA_FILE].freeze

  # Mutual TLS, failing closed: every setting present and readable, or no
  # command is sent.
  def tls_options
    missing = TLS_SETTINGS.select { |name| ENV[name].blank? }
    raise Error, "mutual TLS to the comms connector is not configured (#{missing.join(", ")})" if missing.any?

    {
      use_ssl: true,
      verify_mode: OpenSSL::SSL::VERIFY_PEER,
      ca_file: ENV["COMMS_CONNECTOR_CA_FILE"],
      cert: OpenSSL::X509::Certificate.new(File.read(ENV["COMMS_CONNECTOR_CLIENT_CERT"])),
      key: OpenSSL::PKey.read(File.read(ENV["COMMS_CONNECTOR_CLIENT_KEY"]))
    }
  rescue SystemCallError, OpenSSL::OpenSSLError => e
    raise Error, "mutual TLS to the comms connector is misconfigured (#{e.class})"
  end

  def base_url
    ENV["COMMS_CONNECTOR_URL"].presence
  end

  def deliver(connection, command)
    raise ArgumentError, "unknown comms command #{command}" unless COMMANDS.include?(command)

    unless base_url
      Rails.logger.info("[comms] connector not configured; #{command} intended for #{connection.public_id}")
      return :not_configured
    end

    secret = connection.credential_payload_hash["callback_secret"]
    raise Error, "#{connection.public_id} has no callback secret" if secret.blank?

    uri = URI.join(base_url, "/connections/#{connection.public_id}/#{command}")
    body = JSON.generate(command: command)
    request = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "application/json"
    CommsSignature.headers_for(
      secret:, connection_id: connection.public_id, method: "POST", path: uri.path, body:
    ).each { |name, value| request[name] = value }
    request.body = body

    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https", open_timeout: 5, read_timeout: 15) do |http|
      http.request(request)
    end
    raise Error, "comms connector #{command} failed (#{response.code})" unless response.is_a?(Net::HTTPSuccess)

    :sent
  end

end
