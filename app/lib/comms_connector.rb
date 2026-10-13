require "net/http"

# Rails → comms connector commands. There is no send.
#
# Every command, for every provider, goes over mutual TLS and is signed with
# the connector-wide COMMS_COMMAND_KEY (CommsCommandSignature), because some
# carry secrets: start_pairing / start_login hand the connector the
# connection's callback secret (proposal 2026-10-11 §5, which settles the
# WhatsApp proposal's open "secret bootstrap"). The connector cannot verify a
# command with a secret it does not hold yet, so the per-connection secret is
# only ever used for connector → Rails events (CommsSignature).
#
# WhatsApp and Telegram are separate connectors (Go/whatsmeow and
# Python/Telethon), so each has its own URL: COMMS_WHATSAPP_CONNECTOR_URL and
# COMMS_CONNECTOR_URL. While a provider's URL is unset (development, tests,
# and every deploy before its accessory exists) a command is not sent; the
# intent is logged and :not_configured returned.
module CommsConnector

  COMMANDS = %w[start_pairing unpair].freeze
  WHATSAPP_URL_ENV = "COMMS_WHATSAPP_CONNECTOR_URL".freeze
  # Everything a WhatsApp command needs; the catalog hides WhatsApp until all
  # of it is set.
  WHATSAPP_ENV = [ WHATSAPP_URL_ENV, "COMMS_COMMAND_KEY",
                   "COMMS_CONNECTOR_CLIENT_CERT", "COMMS_CONNECTOR_CLIENT_KEY", "COMMS_CONNECTOR_CA_FILE" ].freeze
  # The same for Telegram (services/telegram-connector).
  TELEGRAM_ENV = [ "COMMS_CONNECTOR_URL", "COMMS_COMMAND_KEY",
                   "COMMS_CONNECTOR_CLIENT_CERT", "COMMS_CONNECTOR_CLIENT_KEY", "COMMS_CONNECTOR_CA_FILE" ].freeze

  class Error < StandardError; end
  # An unpair that could not be sent because no connector is configured.
  # Not a confirmation: the accessory outlives Rails deploys and its
  # configuration, so it may still hold the device.
  class NotConfigured < Error; end

  module_function

  # WhatsApp. start_pairing hands over the callback secret with its version;
  # the connector never installs a version lower than the one it holds.
  def start_pairing(connection)
    payload = connection.credential_payload_hash
    secret = payload["callback_secret"]
    raise Error, "#{connection.public_id} has no callback secret" if secret.blank?

    command(connection, "start_pairing", url: ENV[WHATSAPP_URL_ENV].presence,
                                         callback_secret: secret,
                                         callback_secret_version: [ payload["callback_secret_version"].to_i, 1 ].max)
  end

  def unpair(connection)
    command(connection, "unpair", url: ENV[WHATSAPP_URL_ENV].presence)
  end

  # Unpair, raising NotConfigured instead of returning :not_configured, for
  # callers that must only treat a real reply as confirmation.
  def unpair!(connection)
    result = unpair(connection)
    raise NotConfigured, "no WhatsApp connector is configured" if result == :not_configured

    result
  end

  # Telegram commands (proposal 2026-10-11 §5). Like WhatsApp's, some of
  # these carry secrets (the callback secret, a two-step password), so for
  # both providers:
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

    command(connection, operation, url: base_url, **fields)
  end

  def command(connection, operation, url:, **fields)
    unless url
      Rails.logger.info("[comms] connector not configured; #{operation} intended for #{connection.public_id}")
      return :not_configured
    end

    uri = URI.join(url, "/connections/#{connection.public_id}/#{operation}")
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

end
