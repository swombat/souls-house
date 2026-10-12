# Signs Rails → connector commands for providers whose commands carry
# secrets (Telegram, proposal 2026-10-11 §5) with the connector-wide
# COMMS_COMMAND_KEY. The signed string is
#
#   v1 LF key-id LF connection-public-id LF operation LF command-id LF unix-seconds LF sha256(body)
#
# The body repeats connection, operation, command id and issue time, and for
# login commands the login generation, so the connector checks one against
# the other. The connector rejects a command older than MAX_AGE, a command id
# it has seen, an unknown key id, or a generation that is not current.
module CommsCommandSignature

  MAX_AGE = 60 # seconds
  HEADERS = {
    key_id: "X-Comms-Key-Id",
    command_id: "X-Comms-Command-Id",
    issued_at: "X-Comms-Issued-At",
    signature: "X-Comms-Command-Signature"
  }.freeze

  class MissingKey < StandardError; end

  module_function

  def key_id
    ENV["COMMS_COMMAND_KEY_ID"].presence || "k1"
  end

  def key
    ENV["COMMS_COMMAND_KEY"].presence || raise(MissingKey, "COMMS_COMMAND_KEY is not set")
  end

  def signing_string(key_id:, connection_id:, operation:, command_id:, issued_at:, body:)
    [ "v1", key_id, connection_id, operation, command_id, issued_at.to_s, Digest::SHA256.hexdigest(body) ].join("\n")
  end

  def sign(secret:, **parts)
    OpenSSL::HMAC.hexdigest("SHA256", secret, signing_string(**parts))
  end

  def headers_for(connection_id:, operation:, command_id:, issued_at:, body:)
    signature = sign(secret: key, key_id:, connection_id:, operation:, command_id:, issued_at:, body:)
    {
      HEADERS[:key_id] => key_id,
      HEADERS[:command_id] => command_id,
      HEADERS[:issued_at] => issued_at.to_s,
      HEADERS[:signature] => signature
    }
  end

end
