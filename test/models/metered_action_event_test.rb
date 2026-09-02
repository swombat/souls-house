require "test_helper"

class MeteredActionEventTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:research_assistant)
    @now = Time.zone.parse("2026-09-02 12:00:00")
  end

  test "admits ten resident requests per rolling hour and rejects the next one" do
    10.times do
      assert MeteredActionEvent.admit!(action: "x_read", agent: @agent, now: @now).allowed?
    end

    assert_no_difference -> { MeteredActionEvent.count } do
      admission = MeteredActionEvent.admit!(action: "x_read", agent: @agent, now: @now)

      assert_not admission.allowed?
      assert_includes admission.blocked_by, "agent_hour.requests"
      assert_not admission.request_counted
    end
  end

  test "enforces the resident rolling day request limit" do
    50.times { |index| create_event(agent: @agent, created_at: @now - 2.hours - index.seconds) }

    admission = MeteredActionEvent.admit!(action: "x_read", agent: @agent, now: @now)

    assert_not admission.allowed?
    assert_includes admission.blocked_by, "agent_day.requests"
    assert_not_includes admission.blocked_by, "agent_hour.requests"
  end

  test "enforces the account rolling day request limit across residents" do
    account_agents = [
      agents(:research_assistant),
      agents(:code_reviewer),
      agents(:inactive_agent),
      agents(:with_save_memory_tool),
      agents(:without_tools)
    ]
    account_agents.each do |agent|
      40.times { |index| create_event(agent:, created_at: @now - 2.hours - index.seconds) }
    end

    admission = MeteredActionEvent.admit!(action: "x_read", agent: @agent, now: @now)

    assert_not admission.allowed?
    assert_includes admission.blocked_by, "account_day.requests"
    assert_not_includes admission.blocked_by, "agent_day.requests"
  end

  test "enforces spend caps using exact completed request costs" do
    create_event(
      agent: @agent,
      created_at: @now - 30.minutes,
      outcome: "completed",
      cost_in_usd_ticks: 3_000_000_000
    )

    admission = MeteredActionEvent.admit!(action: "x_read", agent: @agent, now: @now)

    assert_not admission.allowed?
    assert_includes admission.blocked_by, "agent_hour.spend"
    assert_equal @now + 30.minutes, admission.retry_at
  end

  test "enforces the resident rolling day spend cap" do
    create_event(
      agent: @agent,
      created_at: @now - 2.hours,
      outcome: "completed",
      cost_in_usd_ticks: 15_000_000_000
    )

    admission = MeteredActionEvent.admit!(action: "x_read", agent: @agent, now: @now)

    assert_not admission.allowed?
    assert_includes admission.blocked_by, "agent_day.spend"
    assert_not_includes admission.blocked_by, "agent_hour.spend"
  end

  test "enforces the account rolling day spend cap across residents" do
    create_event(
      agent: agents(:code_reviewer),
      created_at: @now - 2.hours,
      outcome: "completed",
      cost_in_usd_ticks: 60_000_000_000
    )

    admission = MeteredActionEvent.admit!(action: "x_read", agent: @agent, now: @now)

    assert_not admission.allowed?
    assert_includes admission.blocked_by, "account_day.spend"
    assert_not_includes admission.blocked_by, "agent_day.spend"
  end

  test "treats in-flight admitted requests as zero spend" do
    create_event(agent: @agent, created_at: @now - 5.minutes, outcome: "admitted")

    admission = MeteredActionEvent.admit!(action: "x_read", agent: @agent, now: @now)

    assert admission.allowed?
    assert_equal "0.0", admission.as_json.dig(:windows, 0, :spend, :used_usd)
  end

  test "expires rows outside the rolling window" do
    10.times do |index|
      create_event(agent: @agent, created_at: @now - 1.hour - index.seconds - 1.second)
    end

    admission = MeteredActionEvent.admit!(action: "x_read", agent: @agent, now: @now)

    assert admission.allowed?
    assert_equal 1, admission.as_json.dig(:windows, 0, :requests, :used)
  end

  test "completion annotates the admission and returns current spend allowance" do
    admission = MeteredActionEvent.admit!(action: "x_read", agent: @agent, now: @now)

    allowance = admission.event.complete!(
      outcome: "completed",
      provider_request_id: "resp_123",
      usage: { "x_search_calls" => 1 },
      cost_in_usd_ticks: 312_190_000,
      now: @now + 1.second
    )

    admission.event.reload
    assert_equal "completed", admission.event.outcome
    assert_equal "resp_123", admission.event.provider_request_id
    assert_equal 312_190_000, admission.event.cost_in_usd_ticks
    assert_equal "0.031219", allowance.as_json.dig(:windows, 0, :spend, :used_usd)
    assert allowance.request_counted
  end

  private

  def create_event(agent:, created_at:, outcome: "admitted", cost_in_usd_ticks: nil)
    MeteredActionEvent.create!(
      account: agent.account,
      agent:,
      action: "x_read",
      request_id: SecureRandom.uuid,
      outcome:,
      provider: "xai",
      cost_in_usd_ticks:,
      created_at:,
      updated_at: created_at
    )
  end

end
