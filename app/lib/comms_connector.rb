require "net/http"

# Rails → comms connector commands, signed with the connection's callback
# secret exactly as the connector signs its events (CommsSignature): start
# pairing, unpair, and send_text (spec §5).
#
# COMMS_CONNECTOR_URL names the private-network connector. While it is unset
# (development, tests, and every deploy before the accessory exists) a
# command is not sent; the intent is logged and :not_configured returned.
module CommsConnector

  COMMANDS = %w[start_pairing unpair send_text].freeze

  # send_text waits this long for the connector's answer, then leaves the
  # send `unknown`. The connector answers once WhatsApp accepts or refuses.
  SEND_OPEN_TIMEOUT = 5
  SEND_READ_TIMEOUT = 20

  class Error < StandardError; end

  # The connector's answer to send_text. status is "sent", "failed" or
  # "unknown"; nothing else is ever returned.
  SendOutcome = Data.define(:status, :provider_message_id, :sent_at, :error_code)

  module_function

  def start_pairing(connection) = deliver(connection, "start_pairing")
  def unpair(connection) = deliver(connection, "unpair")

  # Hands one CommsSend to the connector. The connector records the send ID
  # as attempted before calling WhatsApp and never sends the same ID twice
  # (spec §5); message_id is the WhatsApp message ID it must use.
  #
  # Only an explicit "sent" or "failed" from the connector becomes sent or
  # failed. A timeout, a lost connection, a non-JSON or unrecognised answer
  # is "unknown": the message may or may not have gone.
  def send_text(send)
    connection = send.service_connection
    payload = {
      command: "send_text",
      send_id: send.public_id,
      message_id: send.provider_message_id,
      chat: send.comms_chat.provider_chat_id,
      text: send.text
    }
    response = post(connection, "send_text", payload, open_timeout: SEND_OPEN_TIMEOUT, read_timeout: SEND_READ_TIMEOUT)
    return SendOutcome.new(status: "failed", provider_message_id: nil, sent_at: nil, error_code: "connector_not_configured") if response == :not_configured

    send_outcome(response)
  rescue Timeout::Error
    SendOutcome.new(status: "unknown", provider_message_id: nil, sent_at: nil, error_code: "connector_timeout")
  rescue Error
    # Raised before any request is made (no callback secret): not sent.
    SendOutcome.new(status: "failed", provider_message_id: nil, sent_at: nil, error_code: "no_callback_secret")
  rescue SystemCallError, IOError, OpenSSL::SSL::SSLError, SocketError
    SendOutcome.new(status: "unknown", provider_message_id: nil, sent_at: nil, error_code: "connector_unreachable")
  rescue StandardError
    SendOutcome.new(status: "unknown", provider_message_id: nil, sent_at: nil, error_code: "connector_error")
  end

  def send_outcome(response)
    body = begin
      JSON.parse(response.body.to_s)
    rescue JSON::ParserError
      nil
    end
    body = {} unless body.is_a?(Hash)
    code = body["error_code"].to_s.gsub(/[^a-z0-9_]/i, "").first(64).presence

    if response.is_a?(Net::HTTPSuccess) && body["status"] == "sent" && body["provider_message_id"].present?
      sent_at = begin
        Time.iso8601(body["sent_at"].to_s)
      rescue ArgumentError
        nil
      end
      SendOutcome.new(status: "sent", provider_message_id: body["provider_message_id"].to_s.first(128), sent_at: sent_at, error_code: nil)
    elsif body["status"] == "failed"
      SendOutcome.new(status: "failed", provider_message_id: nil, sent_at: nil, error_code: code || "connector_failed")
    else
      SendOutcome.new(status: "unknown", provider_message_id: nil, sent_at: nil,
                      error_code: code || (response.is_a?(Net::HTTPSuccess) ? "connector_unrecognised" : "connector_http_#{response.code}"))
    end
  end

  def base_url
    ENV["COMMS_CONNECTOR_URL"].presence
  end

  def deliver(connection, command)
    response = post(connection, command, { command: command })
    return response if response == :not_configured
    raise Error, "comms connector #{command} failed (#{response.code})" unless response.is_a?(Net::HTTPSuccess)

    :sent
  end

  def post(connection, command, payload, open_timeout: 5, read_timeout: 15)
    raise ArgumentError, "unknown comms command #{command}" unless COMMANDS.include?(command)

    unless base_url
      Rails.logger.info("[comms] connector not configured; #{command} intended for #{connection.public_id}")
      return :not_configured
    end

    secret = connection.credential_payload_hash["callback_secret"]
    raise Error, "#{connection.public_id} has no callback secret" if secret.blank?

    uri = URI.join(base_url, "/connections/#{connection.public_id}/#{command}")
    body = JSON.generate(payload)
    request = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "application/json"
    CommsSignature.headers_for(
      secret:, connection_id: connection.public_id, method: "POST", path: uri.path, body:
    ).each { |name, value| request[name] = value }
    request.body = body

    Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https", open_timeout:, read_timeout:) do |http|
      http.request(request)
    end
  end

end
