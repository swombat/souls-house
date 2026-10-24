# Signs and verifies requests between Rails and the comms connector, in both
# directions, with the connection's own callback secret (HMAC-SHA256). Shaped
# like RunnerSignature; the signed string is
#
#   connection-public-id LF METHOD LF path LF unix-seconds LF nonce LF raw-body
#
# so a request signed for one connection cannot be replayed against another,
# and the nonce is remembered for the window (CommsRequestNonce).
module CommsSignature

  MAX_SKEW = 300 # seconds
  MAX_BODY_BYTES = 1.megabyte
  NONCE_FORMAT = /\A[0-9a-f]{32}\z/
  HEADERS = {
    connection: "X-Comms-Connection",
    timestamp: "X-Comms-Timestamp",
    nonce: "X-Comms-Nonce",
    signature: "X-Comms-Signature"
  }.freeze

  class Invalid < StandardError

    attr_reader :code

    def initialize(code)
      @code = code
      super(code.to_s)
    end

  end

  module_function

  def signing_string(connection_id:, method:, path:, timestamp:, nonce:, body:)
    [ connection_id, method.to_s.upcase, path, timestamp.to_s, nonce, body ].join("\n")
  end

  def sign(secret:, **parts)
    OpenSSL::HMAC.hexdigest("SHA256", secret, signing_string(**parts))
  end

  # Headers for a signed request (the outbound client, and tests).
  def headers_for(secret:, connection_id:, method:, path:, body:, now: Time.current, nonce: SecureRandom.hex(16))
    timestamp = now.to_i
    {
      HEADERS[:connection] => connection_id,
      HEADERS[:timestamp] => timestamp.to_s,
      HEADERS[:nonce] => nonce,
      HEADERS[:signature] => sign(secret:, connection_id:, method:, path:, timestamp:, nonce:, body:)
    }
  end

  # Returns the verified nonce; raises Invalid. Writes nothing: the caller
  # consumes the nonce in the same transaction as its own change.
  def verify!(secret:, expected_connection_id:, method:, path:, body:, headers:, now: Time.current)
    raise Invalid.new(:body_too_large) if body.bytesize > MAX_BODY_BYTES

    connection_id, timestamp, nonce, signature = HEADERS.values.map { |name| headers[name].to_s }
    raise Invalid.new(:missing_signature) if [ connection_id, timestamp, nonce, signature ].any?(&:empty?)
    raise Invalid.new(:no_secret) if secret.blank?
    raise Invalid.new(:connection_mismatch) unless ActiveSupport::SecurityUtils.secure_compare(connection_id, expected_connection_id.to_s)
    raise Invalid.new(:bad_nonce) unless nonce.match?(NONCE_FORMAT)
    raise Invalid.new(:bad_timestamp) unless timestamp.match?(/\A\d{1,12}\z/)
    raise Invalid.new(:stale_timestamp) if (now.to_i - timestamp.to_i).abs > MAX_SKEW

    expected = sign(secret:, connection_id: expected_connection_id.to_s, method:, path:, timestamp:, nonce:, body:)
    raise Invalid.new(:bad_signature) unless ActiveSupport::SecurityUtils.secure_compare(signature, expected)

    nonce
  end

end
