# Verifies a host runner's signed request. The signed string must match
# host-runner/souls_house_runner.py exactly; the shared vector in
# test/fixtures/files/runner_signature_vector.json pins it in both languages.
#
#   "souls-house-runner-v1" LF method LF path LF sha256-hex(body) LF
#   runner-id LF unix-seconds LF nonce
module RunnerSignature

  VERSION = "souls-house-runner-v1"
  MAX_SKEW = 120 # seconds
  MAX_BODY_BYTES = 64.kilobytes
  NONCE_FORMAT = /\A[0-9a-f]{32}\z/

  class Invalid < StandardError

    attr_reader :code

    def initialize(code)
      @code = code
      super(code.to_s)
    end

  end

  module_function

  def signing_string(method:, path:, body:, runner_id:, timestamp:, nonce:)
    [ VERSION, method.to_s.upcase, path, OpenSSL::Digest::SHA256.hexdigest(body), runner_id, timestamp.to_s, nonce ].join("\n")
  end

  # Returns the verified nonce. Raises Invalid with a code the runner can act
  # on: clock_skew is retried by the runner, everything else is not.
  def verify!(method:, path:, body:, headers:, public_key_b64:, expected_runner_id:, now: Time.current, max_body_bytes: MAX_BODY_BYTES)
    raise Invalid.new(:body_too_large) if body.bytesize > max_body_bytes

    runner_id = headers["X-Runner-Id"].to_s
    timestamp = headers["X-Runner-Timestamp"].to_s
    nonce = headers["X-Runner-Nonce"].to_s
    signature_b64 = headers["X-Runner-Signature"].to_s

    raise Invalid.new(:missing_signature) if [ runner_id, timestamp, nonce, signature_b64 ].any?(&:empty?)
    raise Invalid.new(:runner_mismatch) unless ActiveSupport::SecurityUtils.secure_compare(runner_id, expected_runner_id.to_s)
    raise Invalid.new(:bad_nonce) unless nonce.match?(NONCE_FORMAT)
    raise Invalid.new(:bad_timestamp) unless timestamp.match?(/\A\d{1,12}\z/)
    raise Invalid.new(:clock_skew) if (now.to_i - timestamp.to_i).abs > MAX_SKEW

    key = public_key(public_key_b64)
    signature = Base64.strict_decode64(signature_b64)
    message = signing_string(method:, path:, body:, runner_id:, timestamp:, nonce:)
    raise Invalid.new(:bad_signature) unless key.verify(nil, signature, message)

    nonce
  rescue ArgumentError, OpenSSL::PKey::PKeyError
    raise Invalid.new(:bad_signature)
  end

  def public_key(public_key_b64)
    raw = Base64.strict_decode64(public_key_b64.to_s)
    raise Invalid.new(:bad_public_key) unless raw.bytesize == RunnerEnrollment::PUBLIC_KEY_BYTES

    OpenSSL::PKey.new_raw_public_key("ED25519", raw)
  rescue ArgumentError
    raise Invalid.new(:bad_public_key)
  end

end
