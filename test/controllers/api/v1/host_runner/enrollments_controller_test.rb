require "test_helper"
require_relative "../../../../support/runner_signing"

class Api::V1::HostRunner::EnrollmentsControllerTest < ActionDispatch::IntegrationTest

  include RunnerSigning

  PATH = "/api/v1/host_runner/enrollment".freeze

  setup do
    @placement = AgentPlacement.create!(agent: agents(:research_assistant), backend: "hetzner_cloud", state: "pending")
    @enrollment, @token = RunnerEnrollment.mint!(placement: @placement)
    @key = runner_key
  end

  def enroll(key: @key, token: @token, server: 4242, nonce: SecureRandom.hex(16), timestamp: Time.current.to_i, runner_id: @enrollment.public_id, body: nil)
    body ||= JSON.generate(token:, public_key: public_key_b64(key), facts: { provider_server_id: server, docker_version: "27.0", secret_extra: "dropped" })
    post PATH, params: body, headers: signed_runner_headers(key, path: PATH, body:, runner_id:, nonce:, timestamp:)
  end

  test "pending until procurement confirms the server, then enrolled; the token is not burned while pending" do
    enroll
    assert_response :accepted
    assert_equal "pending", response.parsed_body["status"]
    assert_nil @enrollment.reload.enrolled_at

    @enrollment.confirm_provider_server!(4242)
    enroll
    assert_response :ok
    assert_equal "enrolled", response.parsed_body["status"]
    assert_equal public_key_b64(@key), @enrollment.reload.public_key
    assert_equal({ "provider_server_id" => 4242, "docker_version" => "27.0" }, @enrollment.last_facts)
  end

  test "a lost reply recovers: same key again is already enrolled; a new key is refused" do
    @enrollment.confirm_provider_server!(4242)
    enroll
    enroll
    assert_response :ok
    assert_equal "already_enrolled", response.parsed_body["status"]

    enroll(key: runner_key)
    assert_response :conflict
    assert_equal "key_mismatch", response.parsed_body["error"]
  end

  test "a replayed nonce is refused" do
    @enrollment.confirm_provider_server!(4242)
    nonce = SecureRandom.hex(16)
    enroll(nonce:)
    assert_response :ok
    enroll(nonce:)
    assert_response :unauthorized
    assert_equal "replayed_nonce", response.parsed_body["error"]
  end

  test "clock skew is reported so the runner retries rather than gives up" do
    enroll(timestamp: 10.minutes.ago.to_i)
    assert_response :unauthorized
    assert_equal "clock_skew", response.parsed_body["error"]
  end

  test "a signature by a key other than the one being pinned is refused" do
    body = JSON.generate(token: @token, public_key: public_key_b64(@key), facts: { provider_server_id: 4242 })
    post PATH, params: body, headers: signed_runner_headers(runner_key, path: PATH, body:, runner_id: @enrollment.public_id)
    assert_response :unauthorized
    assert_equal "bad_signature", response.parsed_body["error"]
  end

  test "unknown runner, wrong token, wrong server and oversized bodies are refused" do
    enroll(runner_id: "rnr_doesnotexist0000")
    assert_response :unauthorized
    assert_equal "unknown_runner", response.parsed_body["error"]

    enroll(token: "not-the-token")
    assert_response :unauthorized
    assert_equal "invalid_token", response.parsed_body["error"]

    @enrollment.confirm_provider_server!(4242)
    enroll(server: 1)
    assert_response :conflict
    assert_equal "server_mismatch", response.parsed_body["error"]

    enroll(body: JSON.generate(token: @token, public_key: public_key_b64(@key), padding: "x" * RunnerSignature::MAX_BODY_BYTES))
    assert_response :unauthorized
    assert_equal "body_too_large", response.parsed_body["error"]
    assert_nil @enrollment.reload.enrolled_at
  end

  test "nothing is written for a caller without the token, however well it signs" do
    assert_no_difference -> { RunnerRequestNonce.count } do
      enroll(token: "not-the-token")
      assert_response :unauthorized
      enroll(runner_id: "rnr_doesnotexist0000")
      assert_response :unauthorized
      body = JSON.generate(token: @token, public_key: public_key_b64(@key))
      post PATH, params: body, headers: signed_runner_headers(runner_key, path: PATH, body:, runner_id: @enrollment.public_id)
      assert_response :unauthorized
    end
    enroll
    assert_equal 1, RunnerRequestNonce.count
  end

  test "after the token's lifetime a repeated enrollment is refused, and a signed heartbeat recovers" do
    @enrollment.confirm_provider_server!(4242)
    enroll
    assert_response :ok
    travel 25.hours do
      assert_no_difference -> { RunnerRequestNonce.count } do
        enroll
      end
      assert_response :gone
      assert_equal "expired", response.parsed_body["error"]

      body = JSON.generate(facts: { provider_server_id: 4242 })
      post "/api/v1/host_runner/heartbeat", params: body,
        headers: signed_runner_headers(@key, path: "/api/v1/host_runner/heartbeat", body:, runner_id: @enrollment.public_id)
      assert_response :ok
    end
  end

  test "a repeated enrollment must come from the confirmed server and an unrevoked runner" do
    @enrollment.confirm_provider_server!(4242)
    enroll
    enroll(server: 99)
    assert_response :conflict
    assert_equal "server_mismatch", response.parsed_body["error"]
    @enrollment.revoke!
    enroll
    assert_response :forbidden
    assert_equal "revoked", response.parsed_body["error"]
  end

  test "enrollment never makes the placement ready" do
    @enrollment.confirm_provider_server!(4242)
    enroll
    assert_equal "pending", @placement.reload.state
  end

end
