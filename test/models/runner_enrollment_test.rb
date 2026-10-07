require "test_helper"

class RunnerEnrollmentTest < ActiveSupport::TestCase

  setup do
    @placement = AgentPlacement.create!(agent: agents(:research_assistant), backend: "hetzner_cloud", state: "pending")
    @enrollment, @token = RunnerEnrollment.mint!(placement: @placement, operation_id: 77)
    @key = Base64.strict_encode64(OpenSSL::PKey.generate_key("ED25519").raw_public_key)
  end

  def enroll(token: @token, key: @key, server: 4242, now: Time.current)
    @enrollment.enroll!(token:, public_key: key, reported_server_id: server, facts: { "provider_server_id" => server }, nonce: SecureRandom.hex(16), now:)
  end

  test "mint stores only the digest and a 24 hour expiry" do
    assert_equal RunnerEnrollment.digest(@token), @enrollment.token_digest
    assert_not_includes @enrollment.reload.attributes.values.map(&:to_s), @token
    assert_in_delta 24.hours.from_now, @enrollment.expires_at, 5
    assert_match(/\Arnr_[0-9a-f]{20}\z/, @enrollment.public_id)
  end

  test "before procurement confirms the server, enrollment is pending and burns nothing" do
    assert_equal :pending, enroll
    assert_nil @enrollment.reload.enrolled_at
    assert_nil @enrollment.public_key
    @enrollment.confirm_provider_server!(4242)
    assert_equal :enrolled, enroll
  end

  test "a lost reply recovers with the same key; another key is refused" do
    @enrollment.confirm_provider_server!(4242)
    assert_equal :enrolled, enroll
    assert_equal :already_enrolled, enroll
    other = Base64.strict_encode64(OpenSSL::PKey.generate_key("ED25519").raw_public_key)
    assert_equal :key_mismatch, assert_raises(RunnerEnrollment::Refused) { enroll(key: other) }.code
    assert_equal @key, @enrollment.reload.public_key
  end

  test "refusals" do
    @enrollment.confirm_provider_server!(4242)
    assert_equal :invalid_token, assert_raises(RunnerEnrollment::Refused) { enroll(token: "wrong") }.code
    assert_equal :server_mismatch, assert_raises(RunnerEnrollment::Refused) { enroll(server: 9) }.code
    assert_equal :server_mismatch, assert_raises(RunnerEnrollment::Refused) { enroll(server: nil) }.code
    assert_equal :expired, assert_raises(RunnerEnrollment::Refused) { enroll(now: 25.hours.from_now) }.code
    @enrollment.revoke!
    assert_equal :revoked, assert_raises(RunnerEnrollment::Refused) { enroll }.code
    assert_nil @enrollment.reload.enrolled_at
  end

  test "a spent token is idempotent only inside its lifetime and for the confirmed server" do
    @enrollment.confirm_provider_server!(4242)
    assert_equal :enrolled, enroll
    assert_equal :server_mismatch, assert_raises(RunnerEnrollment::Refused) { enroll(server: 5) }.code
    assert_equal :expired, assert_raises(RunnerEnrollment::Refused) { enroll(now: 25.hours.from_now) }.code
    assert_equal @key, @enrollment.reload.public_key
  end

  test "a refused request leaves no nonce behind; an accepted one consumes exactly one" do
    @enrollment.confirm_provider_server!(4242)
    enroll
    assert_equal 1, @enrollment.request_nonces.count
    other = Base64.strict_encode64(OpenSSL::PKey.generate_key("ED25519").raw_public_key)
    [ -> { enroll(now: 25.hours.from_now) }, -> { enroll(key: other) }, -> { enroll(server: 5) },
      -> { enroll(token: "wrong") },
      -> { @enrollment.heartbeat!(reported_server_id: 5, facts: {}, nonce: SecureRandom.hex(16)) } ].each do |attempt|
      assert_raises(RunnerEnrollment::Refused) { attempt.call }
    end
    @enrollment.revoke!
    assert_raises(RunnerEnrollment::Refused) { enroll }
    assert_raises(RunnerEnrollment::Refused) { @enrollment.heartbeat!(reported_server_id: 4242, facts: {}, nonce: SecureRandom.hex(16)) }
    assert_equal 1, @enrollment.request_nonces.count
  end

  test "a replayed nonce rolls back the change it came with" do
    @enrollment.confirm_provider_server!(4242)
    enroll
    nonce = SecureRandom.hex(16)
    @enrollment.heartbeat!(reported_server_id: 4242, facts: { "uptime_seconds" => 1 }, nonce:)
    error = assert_raises(RunnerSignature::Invalid) do
      @enrollment.heartbeat!(reported_server_id: 4242, facts: { "uptime_seconds" => 2 }, nonce:)
    end
    assert_equal :replayed_nonce, error.code
    assert_equal({ "uptime_seconds" => 1 }, @enrollment.reload.last_facts)
  end

  test "an expired token is refused even before confirmation, so the operation goes to review" do
    assert_equal :expired, assert_raises(RunnerEnrollment::Refused) { enroll(now: 25.hours.from_now) }.code
  end

  test "the confirmed server cannot be changed" do
    @enrollment.confirm_provider_server!(4242)
    @enrollment.confirm_provider_server!(4242)
    assert_equal :provider_server_already_confirmed,
      assert_raises(RunnerEnrollment::Refused) { @enrollment.confirm_provider_server!(5) }.code
  end

  test "health comes from recent heartbeats and lapses" do
    @enrollment.confirm_provider_server!(4242)
    enroll
    assert_not @enrollment.healthy?
    @enrollment.heartbeat!(reported_server_id: 4242, facts: {}, nonce: SecureRandom.hex(16))
    assert @enrollment.healthy?
    assert_not @enrollment.healthy?(now: 4.minutes.from_now)
  end

  test "enrollment and health never make the placement ready" do
    @enrollment.confirm_provider_server!(4242)
    enroll
    @enrollment.heartbeat!(reported_server_id: 4242, facts: {}, nonce: SecureRandom.hex(16))
    assert_equal "pending", @placement.reload.state
    assert_nil @placement.runtime_endpoint
  end

end
