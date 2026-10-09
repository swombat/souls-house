require "test_helper"
require_relative "../../../../support/runner_signing"

class Api::V1::HostRunner::SeedsControllerTest < ActionDispatch::IntegrationTest

  include RunnerSigning

  setup do
    @agent = agents(:research_assistant)
    @agent.update!(container_name: "hk-agent-seed-test")
    @placement = AgentPlacement.create!(agent: @agent, backend: "hetzner_cloud", state: "pending")
    @enrollment, token = RunnerEnrollment.mint!(placement: @placement)
    @enrollment.confirm_provider_server!(4242)
    @key = runner_key
    @enrollment.enroll!(token:, public_key: public_key_b64(@key), reported_server_id: 4242, facts: {}, nonce: SecureRandom.hex(16))
  end

  def fetch(digest, key: @key, runner_id: @enrollment.public_id)
    path = "/api/v1/host_runner/seeds/#{digest}"
    get path, headers: signed_runner_headers(key, path:, body: "", runner_id:, method: "GET")
  end

  def issue(deliver: true)
    command = Agents::VmSeed.new(@agent).issue!
    command.deliver!(now: Time.current) if deliver
    @placement.reload
    command
  end

  test "serves exactly the stored archive a delivered seed_home names" do
    issue
    fetch(@placement.seed_sha256)
    assert_response :ok
    assert_equal @placement.seed_archive, response.body.b
    assert_equal "no-store", response.headers["Cache-Control"]
  end

  test "a digest nobody asked for is not served and spends no nonce" do
    issue
    assert_no_difference -> { RunnerRequestNonce.count } do
      fetch("f" * 64)
    end
    assert_response :not_found
    assert_equal "seed_not_requested", response.parsed_body["error"]
  end

  test "a queued, answered or stale-generation seed does not authorise a fetch" do
    queued = issue(deliver: false)
    fetch(@placement.seed_sha256)
    assert_response :not_found
    queued.deliver!(now: Time.current)
    queued.record_result!({ "outcome" => "done" }, now: Time.current)
    fetch(@placement.seed_sha256)
    assert_response :not_found
    @placement.update!(generation: 2)
    fetch(@placement.seed_sha256)
    assert_response :not_found
  end

  test "another runner cannot fetch this placement's seed" do
    issue
    other_placement = AgentPlacement.create!(agent: agents(:code_reviewer), backend: "hetzner_cloud", state: "pending")
    other, token = RunnerEnrollment.mint!(placement: other_placement)
    other.confirm_provider_server!(5151)
    other_key = runner_key
    other.enroll!(token:, public_key: public_key_b64(other_key), reported_server_id: 5151, facts: {}, nonce: SecureRandom.hex(16))
    fetch(@placement.seed_sha256, key: other_key, runner_id: other.public_id)
    assert_response :not_found
    fetch(@placement.seed_sha256, key: runner_key)
    assert_response :unauthorized
  end

  test "revoked runners and retired placements are refused" do
    issue
    @placement.update!(state: "retired")
    fetch(@placement.seed_sha256)
    assert_response :gone
    @placement.update!(state: "pending")
    @enrollment.revoke!
    fetch(@placement.seed_sha256)
    assert_response :forbidden
  end

end
