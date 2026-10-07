require "test_helper"
require_relative "../support/runner_signing"

class RunnerSignatureTest < ActiveSupport::TestCase

  include RunnerSigning

  VECTOR = JSON.parse(File.read(Rails.root.join("test/fixtures/files/runner_signature_vector.json")))

  def verify_vector(**overrides)
    args = {
      method: VECTOR["method"], path: VECTOR["path"], body: VECTOR["body"], headers: VECTOR["headers"],
      public_key_b64: VECTOR["public_key_b64"], expected_runner_id: VECTOR.dig("headers", "X-Runner-Id"),
      now: Time.zone.at(VECTOR.dig("headers", "X-Runner-Timestamp").to_i)
    }.merge(overrides)
    RunnerSignature.verify!(**args)
  end

  test "Rails verifies the signature the Python runner produced" do
    assert_equal VECTOR.dig("headers", "X-Runner-Nonce"), verify_vector
  end

  test "Rails builds the same signed string as the runner" do
    headers = VECTOR["headers"]
    assert_equal VECTOR["signing_string"], RunnerSignature.signing_string(
      method: "POST", path: VECTOR["path"], body: VECTOR["body"], runner_id: headers["X-Runner-Id"],
      timestamp: headers["X-Runner-Timestamp"], nonce: headers["X-Runner-Nonce"]
    )
  end

  test "any change to body, path or method breaks the signature" do
    [ { body: VECTOR["body"] + " " }, { path: "/api/v1/host_runner/heartbeat" }, { method: "PUT" } ].each do |change|
      error = assert_raises(RunnerSignature::Invalid) { verify_vector(**change) }
      assert_equal :bad_signature, error.code, change.inspect
    end
  end

  test "a different key cannot have signed it" do
    error = assert_raises(RunnerSignature::Invalid) { verify_vector(public_key_b64: public_key_b64(runner_key)) }
    assert_equal :bad_signature, error.code
  end

  test "header and freshness checks" do
    assert_equal :runner_mismatch, assert_raises(RunnerSignature::Invalid) { verify_vector(expected_runner_id: "rnr_other") }.code
    stale = Time.zone.at(VECTOR.dig("headers", "X-Runner-Timestamp").to_i + RunnerSignature::MAX_SKEW + 1)
    assert_equal :clock_skew, assert_raises(RunnerSignature::Invalid) { verify_vector(now: stale) }.code
    assert_equal :missing_signature, assert_raises(RunnerSignature::Invalid) { verify_vector(headers: VECTOR["headers"].except("X-Runner-Signature")) }.code
    assert_equal :bad_nonce, assert_raises(RunnerSignature::Invalid) { verify_vector(headers: VECTOR["headers"].merge("X-Runner-Nonce" => "short")) }.code
    assert_equal :body_too_large, assert_raises(RunnerSignature::Invalid) { verify_vector(body: "x" * (RunnerSignature::MAX_BODY_BYTES + 1)) }.code
    assert_equal :bad_public_key, assert_raises(RunnerSignature::Invalid) { verify_vector(public_key_b64: Base64.strict_encode64("short")) }.code
  end

end
