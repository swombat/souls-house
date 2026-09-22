require "test_helper"
require "webmock/minitest"

class ExternalAgentMemoryAggregationRequestTest < ActiveSupport::TestCase

  test "daily aggregation wakes the hosted agent with continuity instructions" do
    agent = agents(:research_assistant)
    agent.update!(
      runtime: "external",
      uuid: SecureRandom.uuid_v7,
      endpoint_url: "https://agent.example.com",
      trigger_bearer_token: "tr_valid",
      health_state: "healthy",
      consecutive_health_failures: 0
    )

    stub = stub_request(:post, "https://agent.example.com/trigger")
      .with do |request|
        body = JSON.parse(request.body)
        body.fetch("trigger_kind") == "memory_aggregation_daily" &&
          body.fetch("memory_aggregation").slice("period", "target") == { "period" => "daily", "target" => "2026-05-29" } &&
          body.fetch("timeout_secs") == ExternalAgentMemoryAggregationRequest::AGGREGATION_TIMEOUT_SECS &&
          body.fetch("request").include?("daily memory aggregation for 2026-05-29") &&
          body.fetch("request").include?("~/identity/memory/weekly-journals/2026-05-25.md") &&
          body.fetch("request").include?("~/identity/self-narrative.md") &&
          body.fetch("request").include?("Only change it if something feels durable") &&
          body.fetch("request").include?("Do not edit it")
      end
      .to_return(status: 200, body: { status: "ok", stdout: "aggregation changed; self-narrative unchanged" }.to_json)

    assert_difference "AgentRuntimeInteraction.count", 1 do
      result = ExternalAgentMemoryAggregationRequest.new(
        agent: agent,
        period: "daily",
        target: "2026-05-29",
        requested_by: "test"
      ).call

      assert_equal 200, result[:status]
    end

    interaction = AgentRuntimeInteraction.last
    assert_equal "memory_aggregation_daily", interaction.trigger_kind
    assert_equal "aggregation changed; self-narrative unchanged", interaction.stdout
    assert_requested stub
  end

  test "weekly aggregation writes into the month containing the week monday" do
    agent = agents(:research_assistant)
    request = ExternalAgentMemoryAggregationRequest.new(agent: agent, period: "weekly", target: "2026-05-25")

    assert_includes request.send(:request_text), "~/identity/memory/monthly-journals/2026-05.md"
    assert_includes request.send(:request_text), "week of 2026-05-25"
  end

  test "monthly aggregation writes into the year file" do
    agent = agents(:research_assistant)
    request = ExternalAgentMemoryAggregationRequest.new(agent: agent, period: "monthly", target: "2026-05")

    assert_includes request.send(:request_text), "~/identity/memory/yearly-journals/2026.md"
  end

  test "aggregation request includes active house notices" do
    agent = agents(:research_assistant)
    Notice.create!(
      scope: "account",
      account: agent.account,
      notice_type: "announcement",
      body: "Aggregation notice",
      expires_at: 1.day.from_now
    )
    request = ExternalAgentMemoryAggregationRequest.new(agent: agent, period: "monthly", target: "2026-05")

    assert_includes request.send(:request_text), "Aggregation notice"
  end

end
