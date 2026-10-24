require "test_helper"
require_relative "../../../../support/runner_signing"

class Api::V1::HostRunner::CommandsControllerTest < ActionDispatch::IntegrationTest

  include RunnerSigning

  NEXT = "/api/v1/host_runner/commands/next".freeze

  setup do
    @placement = AgentPlacement.create!(agent: agents(:research_assistant), backend: "hetzner_cloud", state: "pending")
    @enrollment, token = RunnerEnrollment.mint!(placement: @placement)
    @enrollment.confirm_provider_server!(4242)
    @key = runner_key
    @enrollment.enroll!(token:, public_key: public_key_b64(@key), reported_server_id: 4242, facts: {}, nonce: SecureRandom.hex(16))
  end

  def signed_post(path, body = "{}", key: @key, runner_id: @enrollment.public_id)
    post path, params: body, headers: signed_runner_headers(key, path:, body:, runner_id:)
  end

  def poll(**options)
    signed_post(NEXT, **options)
    response.parsed_body["command"]
  end

  def answer(command_id, result, **options)
    signed_post("/api/v1/host_runner/commands/#{command_id}/result", JSON.generate(result), **options)
  end

  def enqueue(kind = "stop_resident", payload = { "container_name" => "agent-pilot" })
    RunnerCommand.enqueue!(enrollment: @enrollment, kind:, payload:)
  end

  test "a runner gets its oldest command once, answers it, and the payload is dropped" do
    first = enqueue("start_resident", { "container_name" => "agent-pilot", "env" => { "TRIGGER_BEARER_TOKEN" => "secret" } })
    enqueue

    command = poll
    assert_response :ok
    assert_equal first.public_id, command["id"]
    assert_equal "start_resident", command["kind"]
    assert_equal @placement.generation, command["generation"]
    assert_equal "secret", command.dig("payload", "env", "TRIGGER_BEARER_TOKEN")
    assert_equal "delivered", first.reload.state

    answer(first.public_id, { outcome: "done", result: { state: "running" } })
    assert_response :ok
    first.reload
    assert_equal "done", first.state
    assert_nil first.payload_json
    assert_equal({ "state" => "running" }, first.result["result"])
  end

  test "nothing queued answers with no command" do
    assert_nil poll
    assert_response :ok
  end

  test "the payload is encrypted at rest" do
    command = enqueue("start_resident", { "env" => { "TRIGGER_BEARER_TOKEN" => "plain-secret" } })
    raw = RunnerCommand.connection.select_value("SELECT payload_json FROM runner_commands WHERE id = #{command.id}")
    assert_not_includes raw, "plain-secret"
  end

  test "an unanswered delivery is handed out again only after the redelivery window" do
    command = enqueue
    assert_equal command.public_id, poll["id"]
    assert_nil poll
    travel RunnerCommand::REDELIVER_AFTER + 1.second do
      assert_equal command.public_id, poll["id"]
    end
    assert_equal 2, command.reload.delivery_count
  end

  test "the first answer wins and a repeated answer changes nothing" do
    command = enqueue
    poll
    answer(command.public_id, { outcome: "unknown", error: "runner restarted" })
    answer(command.public_id, { outcome: "done" })
    assert_response :ok
    assert_equal "unknown", command.reload.state
  end

  test "an unrecognised outcome is recorded as unknown, never done" do
    command = enqueue
    poll
    answer(command.public_id, { outcome: "success", result: { "x" => 1 }, extra: "dropped" })
    assert_equal "unknown", command.reload.state
    assert_not command.result.key?("extra")
  end

  test "a command from an older placement generation is refused, not handed out" do
    stale = enqueue
    @placement.update!(generation: @placement.generation + 1)
    fresh = enqueue
    assert_equal fresh.public_id, poll["id"]
    assert_equal "refused", stale.reload.state
    assert_equal "stale generation", stale.result["error"]
    assert_nil stale.payload_json
  end

  test "a late result from an older generation is refused and spends no nonce" do
    command = enqueue
    assert_equal command.public_id, poll["id"]
    @placement.update!(generation: @placement.generation + 1)
    assert_no_difference -> { RunnerRequestNonce.count } do
      answer(command.public_id, { outcome: "done" })
    end
    assert_response :conflict
    assert_equal "stale_generation", response.parsed_body["error"]
    assert_equal "delivered", command.reload.state
  end

  test "a retired placement gets no commands and settles no results" do
    command = enqueue
    poll
    @placement.update!(state: "retired")
    assert_no_difference -> { RunnerRequestNonce.count } do
      assert_nil poll
      assert_response :gone
      answer(command.public_id, { outcome: "done" })
      assert_response :gone
    end
    assert_equal "placement_retired", response.parsed_body["error"]
    assert_equal "delivered", command.reload.state
  end

  test "a runner cannot see or answer another enrollment's commands" do
    other_placement = AgentPlacement.create!(agent: agents(:code_reviewer), backend: "hetzner_cloud", state: "pending")
    other, other_token = RunnerEnrollment.mint!(placement: other_placement)
    other.confirm_provider_server!(5151)
    other_key = runner_key
    other.enroll!(token: other_token, public_key: public_key_b64(other_key), reported_server_id: 5151, facts: {}, nonce: SecureRandom.hex(16))
    mine = enqueue

    assert_nil poll(key: other_key, runner_id: other.public_id)
    answer(mine.public_id, { outcome: "done" }, key: other_key, runner_id: other.public_id)
    assert_response :not_found
    assert_equal "queued", mine.reload.state
  end

  test "a command can't be answered before it was delivered" do
    command = enqueue
    assert_no_difference -> { RunnerRequestNonce.count } do
      answer(command.public_id, { outcome: "done" })
    end
    assert_response :conflict
    assert_equal "queued", command.reload.state
  end

  test "a revoked runner gets nothing and answers nothing, and its nonce is not spent" do
    command = enqueue
    poll
    @enrollment.revoke!
    assert_no_difference -> { RunnerRequestNonce.count } do
      assert_nil poll
      assert_response :forbidden
      answer(command.public_id, { outcome: "done" })
      assert_response :forbidden
    end
    assert_equal "delivered", command.reload.state
  end

  test "only the pinned key can poll, and an unknown runner learns nothing" do
    enqueue
    poll(key: runner_key)
    assert_response :unauthorized
    poll(runner_id: "rnr_nobody")
    assert_response :unauthorized
    assert_equal "unknown_runner", response.parsed_body["error"]
    assert_equal "queued", RunnerCommand.last.state
  end

  test "a replayed poll is refused" do
    enqueue
    body = "{}"
    headers = signed_runner_headers(@key, path: NEXT, body:, runner_id: @enrollment.public_id)
    post NEXT, params: body, headers: headers
    assert_response :ok
    post NEXT, params: body, headers: headers
    assert_response :unauthorized
    assert_equal "replayed_nonce", response.parsed_body["error"]
  end

  test "only known kinds can be queued, and only for the enrollment's own placement" do
    assert_raises(ArgumentError) { RunnerCommand.enqueue!(enrollment: @enrollment, kind: "exec", payload: {}) }
    command = enqueue
    other_placement = AgentPlacement.create!(agent: agents(:code_reviewer), backend: "hetzner_cloud", state: "pending")
    command.agent_placement = other_placement
    assert_not command.valid?
  end

end
