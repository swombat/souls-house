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

  test "the period-only recurring run freezes the target and re-enqueues itself" do
    travel_to Time.utc(2026, 11, 13, 2, 0) do
      assert_enqueued_with(job: ExternalAgentMemoryAggregationJob, args: [ "daily", "2026-11-12" ]) do
        ExternalAgentMemoryAggregationJob.perform_now("daily")
      end
    end
    assert_no_enqueued_jobs(only: ExternalAgentMemoryAggregationAgentJob)
  end

  test "a period-only run retried after midnight keeps the day it was enqueued for" do
    data = travel_to(Time.utc(2026, 11, 12, 23, 55)) { ExternalAgentMemoryAggregationJob.new("daily").serialize }

    travel_to Time.utc(2026, 11, 13, 0, 10) do
      ActiveJob::Base.deserialize(data).perform_now
      perform_enqueued_jobs(only: ExternalAgentMemoryAggregationJob)
    end
    travel_to Time.utc(2026, 11, 13, 0, 40) do
      perform_enqueued_jobs(only: ExternalAgentMemoryAggregationAgentJob)
    end

    assert_requested(:post, "https://agent.example.com/trigger", times: 1) do |request|
      JSON.parse(request.body).dig("memory_aggregation", "target") == "2026-11-11"
    end
  end

  test "an interrupted fan-out retried after midnight completes the same day once per resident" do
    other = agents(:code_reviewer)
    other.update!(runtime: "external", uuid: SecureRandom.uuid_v7, endpoint_url: "https://agent.example.com",
                  trigger_bearer_token: "tr_other", health_state: "healthy", consecutive_health_failures: 0, paused: false)
    other.account.update!(openrouter_api_key: "test-router")
    data = travel_to(Time.utc(2026, 11, 12, 23, 55)) { ExternalAgentMemoryAggregationJob.new("daily").serialize }

    travel_to Time.utc(2026, 11, 12, 23, 56) do
      ActiveJob::Base.deserialize(data).perform_now
      # The fan-out got as far as one child before the worker died.
      ExternalAgentMemoryAggregationAgentJob.perform_now(@agent.id, "daily", "2026-11-11")
      clear_enqueued_jobs
    end
    travel_to Time.utc(2026, 11, 13, 0, 10) do
      ActiveJob::Base.deserialize(data).perform_now
      perform_enqueued_jobs(only: ExternalAgentMemoryAggregationJob)
    end
    travel_to Time.utc(2026, 11, 13, 0, 40) do
      perform_enqueued_jobs(only: ExternalAgentMemoryAggregationAgentJob)
    end

    [ @agent, other ].each do |agent|
      keyed = AgentRuntimeInteraction.where(agent: agent, session_id: ExternalAgentMemoryAggregationRequest.session_id_for(agent, "daily", "2026-11-11"))
      assert_equal 1, keyed.count, "#{agent.name} should run 2026-11-11 exactly once"
    end
    assert_equal 0, AgentRuntimeInteraction.where("session_id LIKE ?", "%-memory-daily-2026-11-12").count
  end

  test "a frozen fan-out retried in full runs each resident once" do
    ExternalAgentMemoryAggregationJob.perform_now("daily", "2026-11-11")
    ExternalAgentMemoryAggregationJob.perform_now("daily", "2026-11-11")

    perform_enqueued_jobs(only: ExternalAgentMemoryAggregationAgentJob)

    assert_requested @stub, times: 1
    assert_equal 1, aggregation_interactions("2026-11-11").count
  end

  test "a finished run holds the key only when the runtime said ok" do
    { { "status" => "ok", "stdout" => "done" } => true,
      { "status" => "error" } => false,
      { "status" => "timeout" } => false,
      { "status" => "ok", "returncode" => 1 } => false }.each do |body, holds|
      interaction = AgentRuntimeInteraction.create!(
        agent: @agent, trigger_kind: "memory_aggregation_daily", requested_by: "test",
        session_id: "probe-#{SecureRandom.hex(4)}", started_at: Time.current
      )
      interaction.record_result!(status: 200, body: body)

      assert_equal holds, ExternalAgentMemoryAggregationRequest.holds_key?(interaction.reload), body.inspect
    end
  end

  test "a runtime error recorded through record_result! does not block the retry" do
    interaction = AgentRuntimeInteraction.create!(
      agent: @agent, trigger_kind: "memory_aggregation_daily", requested_by: "test",
      session_id: ExternalAgentMemoryAggregationRequest.session_id_for(@agent, "daily", "2026-11-11"),
      started_at: 1.minute.ago
    )
    interaction.record_result!(status: 200, body: { "status" => "error", "stdout" => "" })

    ExternalAgentMemoryAggregationAgentJob.perform_now(@agent.id, "daily", "2026-11-11")

    assert_requested @stub, times: 1
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
