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
