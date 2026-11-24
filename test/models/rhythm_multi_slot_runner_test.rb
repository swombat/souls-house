require "test_helper"

class RhythmMultiSlotRunnerTest < ActiveSupport::TestCase

  setup do
    @user = users(:user_1)
    @agent = agents(:research_assistant)
    @morning = Time.utc(2026, 11, 23, 9)
    travel_to @morning - 1.hour
    @rhythm = Rhythm.create!(
      account: @agent.account, creator: @user, title: "Daily looks", opening: "Anything new?",
      agents: [ @agent ], cadence: "daily", times_of_day: [ "09:00", "13:00", "17:00" ], timezone: "UTC"
    )
  end

  teardown { travel_back }

  test "four Madrid slots each open one conversation titled with its scheduled local time" do
    travel_to Time.utc(2026, 11, 23, 0)
    @rhythm.update!(timezone: "Madrid", append_date: true, times_of_day: %w[07:00 12:00 17:00 21:00])
    [ 6, 11, 16, 20 ].each do |hour|
      instant = Time.utc(2026, 11, 23, hour)
      assert_equal instant, @rhythm.reload.next_run_at
      occurrence = @rhythm.fire!(now: instant + 5.minutes).occurrence
      assert_equal instant, occurrence.scheduled_for
      assert_equal "Daily looks — 23 Nov 2026, %02d:00" % (hour + 1), occurrence.chat.title
    end
    assert_equal Time.utc(2026, 11, 24, 6), @rhythm.reload.next_run_at
  end

  test "an outage fires only the latest missed slot and advances to the next normal slot" do
    @rhythm.update_column(:next_run_at, @morning - 3.days)
    result = nil
    assert_difference [ "Chat.count", "RhythmOccurrence.count", "MessageDispatch.count" ], 1 do
      result = @rhythm.fire!(now: @morning + 6.hours)
    end
    assert_equal :created, result.status
    assert_equal @morning + 4.hours, result.occurrence.scheduled_for
    assert_equal @morning + 8.hours, @rhythm.reload.next_run_at
    assert_equal :not_due, @rhythm.fire!(now: @morning + 6.hours).status
    assert_equal :created, @rhythm.fire!(now: @morning + 8.hours).status
    assert_equal [ @morning + 4.hours, @morning + 8.hours ], scheduled_instants
  end

  test "manual requests and their duplicate leave the next normal slot intact" do
    manual_at = @morning - 30.minutes
    first = @rhythm.fire!(now: manual_at, manual: true, request_key: "same-request")
    assert_equal :created, first.status
    assert first.occurrence.manual?
    assert_equal @morning, @rhythm.reload.next_run_at
    assert_no_difference [ "Chat.count", "RhythmOccurrence.count", "MessageDispatch.count" ] do
      duplicate = @rhythm.fire!(now: manual_at + 1.minute, manual: true, request_key: "same-request")
      assert_equal :duplicate, duplicate.status
      assert_equal first.occurrence, duplicate.occurrence
    end
    assert_equal @morning, @rhythm.reload.next_run_at
    assert_equal :created, @rhythm.fire!(now: @morning).status
    assert_equal [ @morning ], scheduled_instants
    assert_equal @morning + 4.hours, @rhythm.reload.next_run_at
  end

  test "a duplicate scheduled delivery advances without replacing the next normal slot" do
    original = @rhythm.fire!(now: @morning).occurrence
    @rhythm.update_column(:next_run_at, @morning)
    assert_no_difference [ "Chat.count", "RhythmOccurrence.count", "MessageDispatch.count" ] do
      duplicate = @rhythm.fire!(now: @morning + 1.minute)
      assert_equal :duplicate, duplicate.status
      assert_equal original, duplicate.occurrence
    end
    assert_equal @morning + 4.hours, @rhythm.reload.next_run_at
    assert_equal :created, @rhythm.fire!(now: @morning + 4.hours).status
    assert_equal [ @morning, @morning + 4.hours ], scheduled_instants
  end

  test "quiet skip advances one slot and fresh news wakes the next normal slot" do
    @rhythm.update!(quiet_gate: true)
    assert_equal :created, @rhythm.fire!(now: @morning).status
    assert_no_difference [ "Chat.count", "RhythmOccurrence.count", "MessageDispatch.count" ] do
      assert_equal :quiet, @rhythm.fire!(now: @morning + 4.hours).status
    end
    assert_equal "skipped_quiet", @rhythm.reload.last_skip_reason
    assert_equal @morning + 8.hours, @rhythm.next_run_at

    chat = @agent.account.chats.create!(
      title: "News", manual_responses: true, agents: [ @agent ], model_id: "openrouter/auto"
    )
    chat.messages.create!(role: "user", user: @user, content: "New information",
      created_at: @morning + 7.hours, suppress_automatic_dispatch: true)
    travel_to @morning + 8.hours
    assert_equal :created, @rhythm.fire!(now: Time.current).status
    assert_equal [ @morning, @morning + 8.hours ], scheduled_instants
    assert_nil @rhythm.reload.last_skip_reason
    assert_equal @morning + 1.day, @rhythm.next_run_at
  end

  test "removing and readding a fired slot does not replay it" do
    assert_equal :created, @rhythm.fire!(now: @morning).status
    travel_to @morning + 1.hour
    @rhythm.update!(times_of_day: [ "13:00", "17:00" ])
    assert_equal @morning + 4.hours, @rhythm.reload.next_run_at
    @rhythm.update!(times_of_day: [ "09:00", "13:00", "17:00" ])
    assert_equal @morning + 4.hours, @rhythm.reload.next_run_at
    assert_no_difference "RhythmOccurrence.count" do
      assert_equal :not_due, @rhythm.fire!(now: Time.current).status
    end
    assert_equal :created, @rhythm.fire!(now: @morning + 4.hours).status
    assert_equal [ @morning, @morning + 4.hours ], scheduled_instants
  end

  private

  def scheduled_instants
    @rhythm.occurrences.where(manual: false).order(:scheduled_for).pluck(:scheduled_for)
  end

end
