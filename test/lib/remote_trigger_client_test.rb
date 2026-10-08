require "test_helper"

class RemoteTriggerClientTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:research_assistant)
    placement = AgentPlacement.create!(agent: @agent, backend: "hetzner_cloud", state: "ready", provider_server_id: 4242)
    @enrollment, token = RunnerEnrollment.mint!(placement:)
    @enrollment.confirm_provider_server!(4242)
    @enrollment.enroll!(token:, public_key: Base64.strict_encode64("k" * 32), reported_server_id: 4242, facts: {}, nonce: SecureRandom.hex(16))
    interaction = AgentRuntimeInteraction.create!(agent: @agent, trigger_kind: "wake", session_id: "s",
      started_at: Time.current, endpoint_url: "runner://#{@enrollment.public_id}")
    @turn = ResidentTurn.create!(agent: @agent, agent_runtime_interaction: interaction, dispatch_id: SecureRandom.uuid,
      session_id: "s", payload: "{}")
    @now = Time.current
  end

  # The "runner": answers the oldest open command when the client sleeps.
  def client(answer: nil)
    sleeper = lambda do |seconds|
      @now += seconds
      next unless answer

      command = RunnerCommand.where.not(state: RunnerCommand::TERMINAL).order(:id).first
      next unless command

      command.deliver!(now: @now) if command.state == "queued"
      command.record_result!(answer.call(command), now: @now)
    end
    RemoteTriggerClient.new(enrollment: @enrollment, agent: @agent, resident_turn: @turn, sleeper:, clock: -> { @now })
  end

  def relayed(status, body) = ->(_c) { { "outcome" => "done", "result" => { "status" => status, "body" => body } } }

  test "the trigger server's answer comes back as the client's answer" do
    response = client(answer: relayed(200, { "id" => @turn.dispatch_id, "state" => "running" })).turn_status(@turn.dispatch_id)
    assert_equal({ status: 200, body: { "id" => @turn.dispatch_id, "state" => "running" } }, response)
    command = RunnerCommand.last
    assert_equal [ "turn_status", @turn.id ], [ command.kind, command.resident_turn_id ]
  end

  test "only the resident's own 404 is a 404; no runner trouble ever becomes one" do
    assert_equal 404, client(answer: relayed(404, { "ledger_id" => "x" })).turn_status(@turn.dispatch_id)[:status]
    {
      "failed" => 502, "refused" => 502, "unknown" => 503
    }.each do |outcome, expected|
      response = client(answer: ->(_c) { { "outcome" => outcome, "error" => "x" } }).turn_status(@turn.dispatch_id)
      assert_equal expected, response[:status], outcome
    end
    malformed = client(answer: ->(_c) { { "outcome" => "done", "result" => { "status" => "404", "body" => {} } } })
    assert_equal 502, malformed.turn_status(@turn.dispatch_id)[:status]
  end

  test "no answer within the wait is a 504, and the next call reuses the same command" do
    assert_equal 504, client.submit_turn(@turn.dispatch_id, { "request" => "hi" }, ledger_id: SecureRandom.uuid)[:status]
    assert_equal 504, client.submit_turn(@turn.dispatch_id, { "request" => "hi" }, ledger_id: SecureRandom.uuid)[:status]
    assert_equal 1, RunnerCommand.where(kind: "submit_turn").count
  end

  test "an answered submission is not reused: a later call is a new command" do
    client(answer: relayed(202, { "id" => @turn.dispatch_id, "state" => "accepted" })).submit_turn(@turn.dispatch_id, {}, ledger_id: SecureRandom.uuid)
    client(answer: relayed(202, { "id" => @turn.dispatch_id, "state" => "accepted" })).submit_turn(@turn.dispatch_id, {}, ledger_id: SecureRandom.uuid)
    assert_equal 2, RunnerCommand.where(kind: "submit_turn").count
  end

  test "containment is not offered remotely" do
    assert_equal 501, client.resolve_turn(@turn.dispatch_id)[:status]
  end

end
