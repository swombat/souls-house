require "test_helper"

class RollHoldWatchJobTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:research_assistant)
    @agent.update!(active: false, paused: true, health_state: "unhealthy", last_health_check_at: 1.hour.ago)
    @hold = ResidentSwitchedOffNotice.switched_off!(@agent, image: "fixture:new")
    @chat = Chat.find(@hold.data.fetch("chat_id"))
  end

  def still_off_notices
    AuditLog.where(action: "resident_roll_hold_still_off", auditable: @agent)
  end

  test "switch-off opens a conversation in Main that wakes nobody" do
    assert_nil @chat.room
    assert_equal [ @agent ], @chat.agents.to_a
    assert_empty MessageDispatch.where(chat: @chat)
    assert_equal @agent.account, @chat.account
    link = @chat.messages.sole.notice_link.stringify_keys
    assert_equal "Settings", link["label"]
    assert_equal Rails.application.routes.url_helpers.edit_account_agent_path(@agent.account, @agent, tab: "settings"), link["path"]
  end

  test "says nothing while the runtime is still unhealthy" do
    RollHoldWatchJob.perform_now
    assert_empty still_off_notices
  end

  test "healthy again but still off is said once, in the hold's conversation" do
    @agent.update!(health_state: "healthy", last_health_check_at: 1.minute.from_now)
    2.times { RollHoldWatchJob.perform_now }
    assert_equal 1, still_off_notices.count
    assert_equal 2, @chat.messages.count
    assert_includes @chat.messages.last.content, "still switched off"
  end

  test "a health check from before the hold doesn't count" do
    @agent.update!(health_state: "healthy", last_health_check_at: @hold.created_at - 1.minute)
    RollHoldWatchJob.perform_now
    assert_empty still_off_notices
  end

  test "a resident switched back on is done" do
    @agent.update!(active: true, paused: false, health_state: "healthy", last_health_check_at: 1.minute.from_now)
    RollHoldWatchJob.perform_now
    assert_empty still_off_notices
  end

  test "only the latest hold for a resident speaks" do
    newer = travel_to(1.minute.from_now) { ResidentSwitchedOffNotice.switched_off!(@agent, image: "fixture:newer") }
    @agent.update!(health_state: "healthy", last_health_check_at: 2.minutes.from_now)
    RollHoldWatchJob.perform_now
    assert_equal [ newer.id.to_s ], still_off_notices.map { |log| log.data["hold_id"].to_s }
  end

end
