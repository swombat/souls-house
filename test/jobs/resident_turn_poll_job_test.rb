require "test_helper"
require "webmock/minitest"

class ResidentTurnPollJobTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:research_assistant)
    @agent.update!(trigger_bearer_token: "synthetic")
    interaction = AgentRuntimeInteraction.create!(
      agent: @agent, trigger_kind: "wake", session_id: "synthetic",
      started_at: Time.current, endpoint_url: "https://runtime.example.test"
    )
    @turn = ResidentTurn.enqueue!(interaction, { session_id: "synthetic", request: "prompt" })
    ResidentTurn.admit!
    @url = "https://runtime.example.test/turns/#{@turn.dispatch_id}"
    @ledger = SecureRandom.uuid
  end

  def status(state, **extra)
    { id: @turn.dispatch_id, ledger_id: @ledger, state: state, **extra }.to_json
  end

  test "lost submission reply retries the identical id and payload on the same ledger" do
    stub_request(:get, @url).to_return(status: 404, body: { ledger_id: @ledger }.to_json)
    stub_request(:post, @url).to_timeout
    ResidentTurnPollJob.perform_now(@turn.id)
    assert_equal @ledger, @turn.reload.ledger_id
    assert_nil @turn.finished_at
    stub_request(:get, @url).to_return(status: 200, body: status("running"))
    ResidentTurnPollJob.perform_now(@turn.id)
    assert_equal "running", @turn.reload.state
    assert_requested :post, @url, times: 1
  end

  test "lost ledger cannot replay even when acceptance reply was lost" do
    @turn.update!(ledger_id: SecureRandom.uuid)
    stub_request(:get, @url).to_return(status: 404, body: { ledger_id: @ledger }.to_json)
    ResidentTurnPollJob.perform_now(@turn.id)
    assert_equal "unknown", @turn.reload.state
    assert_not_requested :post, @url
  end

  test "old runtime does not cause a synchronous fallback" do
    stub_request(:get, @url).to_return(status: 404, body: "{}")
    ResidentTurnPollJob.perform_now(@turn.id)
    assert_equal "starting", @turn.reload.state
    assert_not_requested :post, /runtime\.example\.test/
  end

  test "terminal ledger result completes accounting even when callback was lost" do
    stub_request(:get, @url).to_return(status: 200, body: status("finished",
      result: { status: 200, body: { status: "ok", returncode: 0 } }))
    ResidentTurnPollJob.perform_now(@turn.id)
    assert_equal "finished", @turn.reload.state
    assert_equal "ok", @turn.agent_runtime_interaction.reload.runtime_status
    assert @turn.agent_runtime_interaction.finished_at?
  end

  test "unknown remains reserved beyond the old timeout grace" do
    stub_request(:get, @url).to_return(status: 200, body: status("unknown"))
    ResidentTurnPollJob.perform_now(@turn.id)
    travel 2.days do
      assert_equal 1, ResidentTurn.occupying_capacity.count
      assert_nil @turn.reload.finished_at
    end
  end

  test "cancellation before acceptance creates a runtime tombstone without launching" do
    @turn.update!(cancel_requested_at: Time.current)
    stub_request(:get, @url).to_return(status: 404, body: { ledger_id: @ledger }.to_json)
    stub_request(:delete, @url)
      .with(headers: { "X-Resident-Ledger-ID" => @ledger })
      .to_return(status: 200, body: status("cancelled",
        result: { status: 409, body: { status: "cancelled" } }))
    ResidentTurnPollJob.perform_now(@turn.id)
    assert_equal "cancelled", @turn.reload.state
    assert_not_requested :post, @url
  end

  test "a failed cancellation transport cannot regress running to starting" do
    @turn.update!(cancel_requested_at: Time.current)
    stub_request(:get, @url).to_return(status: 200, body: status("running"))
    stub_request(:delete, @url).to_timeout
    ResidentTurnPollJob.perform_now(@turn.id)
    assert_equal "running", @turn.reload.state
  end

end
