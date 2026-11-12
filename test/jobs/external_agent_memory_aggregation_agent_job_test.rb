require "test_helper"
require "webmock/minitest"

class ExternalAgentMemoryAggregationAgentJobTest < ActiveJob::TestCase

  setup do
    @agent = agents(:research_assistant)
    @agent.update!(
      runtime: "external",
      uuid: SecureRandom.uuid_v7,
      endpoint_url: "https://agent.example.com",
      trigger_bearer_token: "tr_valid",
      health_state: "healthy",
      consecutive_health_failures: 0,
      paused: false
    )
    @agent.account.update!(openrouter_api_key: "test-router")
    @stub = stub_request(:post, "https://agent.example.com/trigger")
      .to_return(status: 200, body: { status: "ok", stdout: "done" }.to_json)
  end

  test "offset is stable per resident and inside the spread" do
    first = ExternalAgentMemoryAggregationJob.offset_for(@agent)

    assert_equal first, ExternalAgentMemoryAggregationJob.offset_for(@agent.reload)
    offsets = Agent.limit(50).map { |agent| ExternalAgentMemoryAggregationJob.offset_for(agent) }
    assert offsets.all? { |offset| offset >= 0 && offset < ExternalAgentMemoryAggregationJob::SPREAD }
  end

  test "parent fans out one delayed child per eligible resident with the frozen target" do
    travel_to Time.utc(2026, 11, 13, 2, 0) do
      assert_enqueued_with(
        job: ExternalAgentMemoryAggregationAgentJob,
        args: [ @agent.id, "daily", "2026-11-11" ],
        at: Time.current + ExternalAgentMemoryAggregationJob.offset_for(@agent)
      ) do
        ExternalAgentMemoryAggregationJob.perform_now("daily", "2026-11-11")
      end
    end
    assert_not_requested @stub
  end

  test "the target frozen before midnight is the one aggregated after it" do
    travel_to Time.utc(2026, 11, 12, 23, 55) do
      ExternalAgentMemoryAggregationJob.perform_now("daily")
    end

    travel_to Time.utc(2026, 11, 13, 0, 20) do
      perform_enqueued_jobs(only: ExternalAgentMemoryAggregationAgentJob)
    end

    assert_requested(:post, "https://agent.example.com/trigger", times: 1) do |request|
      JSON.parse(request.body).dig("memory_aggregation", "target") == "2026-11-11"
    end
  end

  test "a retried parent after a partial fan-out runs each resident once" do
    ExternalAgentMemoryAggregationJob.perform_now("daily", "2026-11-11")
    ExternalAgentMemoryAggregationJob.perform_now("daily", "2026-11-11")

    perform_enqueued_jobs(only: ExternalAgentMemoryAggregationAgentJob)

    assert_requested @stub, times: 1
    assert_equal 1, aggregation_interactions("2026-11-11").count
  end

  test "a retried child after its request was accepted does not run again" do
    ExternalAgentMemoryAggregationAgentJob.perform_now(@agent.id, "daily", "2026-11-11")
    ExternalAgentMemoryAggregationAgentJob.perform_now(@agent.id, "daily", "2026-11-11")

    assert_requested @stub, times: 1
  end

  test "a still-running accepted request also holds the key" do
    AgentRuntimeInteraction.create!(
      agent: @agent, trigger_kind: "memory_aggregation_daily", requested_by: "test",
      session_id: ExternalAgentMemoryAggregationRequest.session_id_for(@agent, "daily", "2026-11-11"),
      started_at: Time.current, transport_status: 202
    )

    ExternalAgentMemoryAggregationAgentJob.perform_now(@agent.id, "daily", "2026-11-11")

    assert_not_requested @stub
  end

  test "a failed earlier attempt does not hold the key" do
    AgentRuntimeInteraction.create!(
      agent: @agent, trigger_kind: "memory_aggregation_daily", requested_by: "test",
      session_id: ExternalAgentMemoryAggregationRequest.session_id_for(@agent, "daily", "2026-11-11"),
      started_at: 1.minute.ago, finished_at: Time.current, transport_status: 500
    )

    ExternalAgentMemoryAggregationAgentJob.perform_now(@agent.id, "daily", "2026-11-11")

    assert_requested @stub, times: 1
  end

  test "the key is per target: another day still runs" do
    ExternalAgentMemoryAggregationAgentJob.perform_now(@agent.id, "daily", "2026-11-10")
    ExternalAgentMemoryAggregationAgentJob.perform_now(@agent.id, "daily", "2026-11-11")

    assert_requested @stub, times: 2
  end

  test "eligibility is re-read when the delayed run fires" do
    ExternalAgentMemoryAggregationJob.perform_now("daily", "2026-11-11")
    @agent.update!(paused: true)

    perform_enqueued_jobs(only: ExternalAgentMemoryAggregationAgentJob)

    assert_not_requested @stub
  end

  test "a resident billing-held after enqueue is skipped" do
    ExternalAgentMemoryAggregationJob.perform_now("daily", "2026-11-11")
    ResidentEntitlement.where(agent: @agent).delete_all
    ResidentEntitlement.create!(agent: @agent, account: @agent.account, source: "stripe", state: "held", tier: "work")

    perform_enqueued_jobs(only: ExternalAgentMemoryAggregationAgentJob)

    assert_not_requested @stub
  end

  private

  def aggregation_interactions(target)
    AgentRuntimeInteraction.where(
      agent: @agent,
      session_id: ExternalAgentMemoryAggregationRequest.session_id_for(@agent, "daily", target)
    )
  end

end
