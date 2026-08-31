require "test_helper"

class ResidentSessionActivityReportTest < ActiveSupport::TestCase

  setup do
    @now = Time.utc(2026, 8, 31, 12)
    @resident = agents(:research_assistant)
    @other_resident = agents(:other_account_agent)
  end

  test "groups logical sessions across residents and classifies their channels" do
    create_interaction!(@resident,
      started_at: @now - 2.hours,
      finished_at: @now - 110.minutes,
      session_id: "web-session",
      trigger_kind: "conversation")
    create_interaction!(@resident,
      started_at: @now - 1.hour,
      finished_at: @now - 50.minutes,
      session_id: "web-session",
      trigger_kind: "conversation")
    create_interaction!(@other_resident,
      started_at: @now - 30.minutes,
      finished_at: @now - 20.minutes,
      session_id: "telegram-session",
      trigger_kind: "telegram")

    report = ResidentSessionActivityReport.new(now: @now, time_zone: "Europe/Madrid").call

    assert_equal 2, report.dig(:summary, :active_residents)
    assert_equal 2, report.dig(:summary, :sessions)
    assert_equal 3, report.dig(:summary, :interactions)
    assert_equal({ "web" => 2, "telegram" => 1 }, report.dig(:summary, :channels))

    sessions = report.fetch(:sessions).index_by { |session| session[:session_id] }
    assert_equal "Web chat", sessions.fetch("web-session").fetch(:channel_label)
    assert_equal 2, sessions.fetch("web-session").fetch(:interaction_count)
    assert_equal @resident.account.name, sessions.fetch("web-session").dig(:resident, :account_name)
    assert_equal "Telegram", sessions.fetch("telegram-session").fetch(:channel_label)
  end

  test "reports only genuinely recent unfinished interactions as running" do
    create_interaction!(@resident,
      started_at: @now - 5.minutes,
      finished_at: nil,
      session_id: "running")
    create_interaction!(@other_resident,
      started_at: @now - 20.minutes,
      finished_at: nil,
      session_id: "stale")

    report = ResidentSessionActivityReport.new(now: @now).call
    sessions = report.fetch(:sessions).index_by { |session| session[:session_id] }

    assert_equal 1, report.dig(:summary, :running_sessions)
    assert_equal "running", sessions.fetch("running").fetch(:status)
    assert_equal "stale", sessions.fetch("stale").fetch(:status)
  end

  test "builds seven local calendar days of activity including empty days" do
    create_interaction!(@resident,
      started_at: Time.utc(2026, 8, 30, 22, 30),
      finished_at: Time.utc(2026, 8, 30, 22, 40),
      session_id: "madrid-monday",
      trigger_kind: "wake")

    report = ResidentSessionActivityReport.new(now: @now, time_zone: "Europe/Madrid").call
    days = report.dig(:activity, :days)

    assert_equal 7, days.size
    assert_equal "2026-08-25", days.first.fetch(:date)
    monday = days.find { |day| day[:date] == "2026-08-31" }
    assert_equal 1, monday.fetch(:interactions)
    assert_equal({ "wake" => 1 }, monday.fetch(:channels))
  end

  test "filters the selected window by channel without changing the weekly chart" do
    create_interaction!(@resident,
      started_at: @now - 30.minutes,
      finished_at: @now - 20.minutes,
      session_id: "web",
      trigger_kind: "conversation")
    create_interaction!(@other_resident,
      started_at: @now - 20.minutes,
      finished_at: @now - 10.minutes,
      session_id: "telegram",
      trigger_kind: "telegram")

    report = ResidentSessionActivityReport.new(now: @now, window: "1h", channel: "telegram").call

    assert_equal "telegram", report.fetch(:selected_channel)
    assert_equal [ "telegram" ], report.fetch(:sessions).map { |session| session[:channel] }
    assert_equal 1, report.dig(:summary, :interactions)
    assert_equal 2, report.dig(:activity, :days).sum { |day| day[:interactions] }
  end

  private

  def create_interaction!(agent, **attributes)
    agent.agent_runtime_interactions.create!(
      {
        trigger_kind: "conversation",
        session_id: SecureRandom.hex(4),
        started_at: @now,
        provider: "openai",
        model: "gpt-5.5"
      }.merge(attributes)
    )
  end

end
