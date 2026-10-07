# Test-side signer for host runner requests: the same signed string as
# host-runner/souls_house_runner.py, produced with Ruby's OpenSSL.
module RunnerSigning

  def runner_key
    OpenSSL::PKey.generate_key("ED25519")
  end

  def public_key_b64(key)
    Base64.strict_encode64(key.raw_public_key)
  end

  def signed_runner_headers(key, path:, body:, runner_id:, timestamp: Time.current.to_i, nonce: SecureRandom.hex(16), method: "POST")
    message = RunnerSignature.signing_string(method:, path:, body:, runner_id:, timestamp:, nonce:)
    {
      "CONTENT_TYPE" => "application/json",
      "X-Runner-Id" => runner_id,
      "X-Runner-Timestamp" => timestamp.to_s,
      "X-Runner-Nonce" => nonce,
      "X-Runner-Signature" => Base64.strict_encode64(key.sign(nil, message))
    }
  end

end
