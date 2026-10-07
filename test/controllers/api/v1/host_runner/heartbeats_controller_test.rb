require "test_helper"
require_relative "../../../../support/runner_signing"

class Api::V1::HostRunner::HeartbeatsControllerTest < ActionDispatch::IntegrationTest

  include RunnerSigning

  PATH = "/api/v1/host_runner/heartbeat".freeze

  setup do
    @placement = AgentPlacement.create!(agent: agents(:research_assistant), backend: "hetzner_cloud", state: "pending")
    @enrollment, @token = RunnerEnrollment.mint!(placement: @placement)
    @enrollment.confirm_provider_server!(4242)
    @key = runner_key
  end

  def enroll!
    @enrollment.enroll!(token: @token, public_key: public_key_b64(@key), reported_server_id: 4242, facts: {})
  end

  def beat(key: @key, server: 4242)
    body = JSON.generate(facts: { provider_server_id: server, uptime_seconds: 60, command: "rm -rf /" })
    post PATH, params: body, headers: signed_runner_headers(key, path: PATH, body:, runner_id: @enrollment.public_id)
  end

  test "an enrolled runner's signed heartbeat records facts and health" do
    enroll!
    beat
    assert_response :ok
    assert @enrollment.reload.healthy?
    assert_equal({ "provider_server_id" => 4242, "uptime_seconds" => 60 }, @enrollment.last_facts)
    assert_equal "pending", @placement.reload.state
  end

  test "before enrollment the runner is indistinguishable from an unknown one" do
    beat
    assert_response :unauthorized
    assert_equal "unknown_runner", response.parsed_body["error"]
  end

  test "only the pinned key can heartbeat" do
    enroll!
    beat(key: runner_key)
    assert_response :unauthorized
    assert_equal "bad_signature", response.parsed_body["error"]
    assert_nil @enrollment.reload.last_heartbeat_at
  end

  test "a heartbeat from another server is refused, and a revoked runner is refused" do
    enroll!
    beat(server: 7)
    assert_response :conflict
    @enrollment.revoke!
    beat
    assert_response :forbidden
    assert_equal "revoked", response.parsed_body["error"]
  end

end
