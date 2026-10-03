require "test_helper"

class RhythmTest < ActiveSupport::TestCase

  setup do
    @user = users(:user_1)
    @agent = agents(:research_assistant)
    @account = @agent.account
    @now = Time.utc(2026, 10, 3, 10)
    @rhythm = Rhythm.create!(
      account: @account, creator: @user, title: "Morning look", opening: "What is taking shape?",
      agents: [ @agent ], cadence: "daily", time_of_day: "09:00", timezone: "UTC",
      next_run_at: @now - 1.day
    )
  end

  test "default date suffix uses the scheduled date in the rhythm zone" do
    assert @rhythm.append_date?
    @rhythm.timezone = "Madrid"
    assert_equal "Morning look — 4 Oct 2026", @rhythm.preview_title(at: Time.utc(2026, 10, 3, 23))
    @rhythm.append_date = false
    assert_equal "Morning look", @rhythm.preview_title(at: @now)
  end

  test "daily and weekly occurrences are strictly after the given instant" do
    assert_equal Time.utc(2026, 10, 4, 9), @rhythm.next_occurrence(after: @now)
    @rhythm.assign_attributes(cadence: "weekly", weekday: 1)
    assert_equal Time.utc(2026, 10, 5, 9), @rhythm.next_occurrence(after: @now)
    assert_equal Time.utc(2026, 10, 12, 9), @rhythm.next_occurrence(after: Time.utc(2026, 10, 5, 9))
  end

  test "monthly date is clamped without drifting the next month's day" do
    @rhythm.assign_attributes(cadence: "monthly", month_day: 31)
    february = @rhythm.next_occurrence(after: Time.utc(2027, 2, 1))
    assert_equal Time.utc(2027, 2, 28, 9), february
    assert_equal Time.utc(2027, 3, 31, 9), @rhythm.next_occurrence(after: february)
  end

  test "yearly leap day clamps in ordinary years and returns in leap years" do
    @rhythm.assign_attributes(cadence: "yearly", month: 2, month_day: 29)
    assert_equal Time.utc(2027, 2, 28, 9), @rhythm.next_occurrence(after: Time.utc(2027, 1, 1))
    assert_equal Time.utc(2028, 2, 29, 9), @rhythm.next_occurrence(after: Time.utc(2027, 3, 1))
  end

  test "DST gap and fold use ActiveSupport local semantics once per local date" do
    @rhythm.assign_attributes(timezone: "Madrid", time_of_day: "02:30")
    zone = ActiveSupport::TimeZone["Madrid"]
    gap = @rhythm.next_occurrence(after: Time.utc(2026, 3, 29))
    assert_equal zone.local(2026, 3, 29, 2, 30).utc, gap
    fold = @rhythm.next_occurrence(after: Time.utc(2026, 10, 25))
    assert_equal zone.local(2026, 10, 25, 2, 30).utc, fold
    assert_equal Date.new(2026, 10, 26), @rhythm.next_occurrence(after: fold).in_time_zone(zone).to_date
  end

  test "malformed schedule reports validation errors rather than date exceptions" do
    @rhythm.assign_attributes(cadence: "yearly", month: 13, month_day: 0, time_of_day: "25:00", timezone: "Unknown")
    assert_not @rhythm.valid?
    assert @rhythm.errors[:month].present?
    assert @rhythm.errors[:month_day].present?
    assert @rhythm.errors[:time_of_day].present?
    assert @rhythm.errors[:timezone].present?
  end

  test "latest missed occurrence creates one attributed room and explicit durable dispatch" do
    @rhythm.update_column(:next_run_at, Time.utc(2020, 1, 1, 9))
    result = nil
    assert_difference [ "Chat.count", "Message.count", "RhythmOccurrence.count", "MessageDispatch.count" ], 1 do
      assert_enqueued_jobs 1, only: MessageDispatchJob do
        result = @rhythm.fire!(now: @now)
      end
    end
    assert_equal :created, result.status
    occurrence = result.occurrence
    assert_equal Time.utc(2026, 10, 3, 9), occurrence.scheduled_for
    assert_equal Time.utc(2026, 10, 4, 9), @rhythm.reload.next_run_at
    assert_equal @user, occurrence.message.user
    assert_equal "user", occurrence.message.role
    assert_equal @rhythm.opening, occurrence.message.content
    assert_equal "Morning look — 3 Oct 2026", occurrence.title
    assert_equal "rhythm", occurrence.message_dispatch.kind
    assert_equal [ @agent.id ], occurrence.message_dispatch.target_agent_ids
    assert_equal @user.full_name, occurrence.creator_label
    assert_not occurrence.manual?
    assert_no_difference "Chat.count" do
      assert_equal :not_due, @rhythm.fire!(now: @now).status
    end
  end

  test "manual start is keyed and does not advance the schedule" do
    original_next_run = @rhythm.next_run_at
    first = @rhythm.fire!(now: @now, manual: true, request_key: "manual-1")
    assert first.occurrence.manual?
    assert_equal @now, first.occurrence.scheduled_for
    assert_equal original_next_run, @rhythm.reload.next_run_at
    @rhythm.pause!(holder: @user, reason: "Wait")
    assert_no_difference "Chat.count" do
      retry_result = @rhythm.fire!(now: @now + 1.hour, manual: true, request_key: "manual-1")
      assert_equal :duplicate, retry_result.status
      assert_equal first.occurrence, retry_result.occurrence
      assert_equal :held, @rhythm.fire!(now: @now, manual: true, request_key: "manual-2").status
    end
    assert_equal :invalid_request, @rhythm.fire!(manual: true).status
  end

  test "human resume does not erase resident holds after selection removal" do
    @rhythm.pause!(holder: @agent, reason: "I need quiet")
    @rhythm.pause!(holder: @user, reason: "Human pause")
    @rhythm.agents = [ agents(:code_reviewer) ]
    @rhythm.save!
    assert_equal :held, @rhythm.resume!(holder: @user).status
    assert_equal [ "agent" ], @rhythm.open_holds.pluck(:kind)
    assert_equal :forbidden, @rhythm.resume!(holder: agents(:code_reviewer)).status
    assert_equal :active, @rhythm.resume!(holder: @agent).status
    assert_equal 2, @rhythm.holds.where.not(released_at: nil).count
  end

  test "last hold release advances past missed work instead of catching up" do
    @rhythm.pause!(holder: @agent, reason: "Quiet")
    @rhythm.update_column(:next_run_at, Time.utc(2020, 1, 1))
    travel_to @now do
      assert_equal :active, @rhythm.resume!(holder: @agent).status
      assert_equal Time.utc(2026, 10, 4, 9), @rhythm.reload.next_run_at
      assert_equal :not_due, @rhythm.fire!(now: @now).status
    end
  end

  test "one paused resident among several blocks the whole occurrence visibly" do
    second = agents(:code_reviewer)
    @rhythm.agents = [ @agent, second ]
    @rhythm.save!
    second.update!(paused: true)
    assert_no_difference "Chat.count" do
      result = @rhythm.fire!(now: @now)
      assert_equal :unavailable, result.status
      assert_equal "resident_paused: #{second.name}", result.reason
    end
    assert_equal 1, @rhythm.open_holds.count
  end

  test "opening and pause reason are bounded" do
    @rhythm.opening = "x" * 20_001
    assert_not @rhythm.valid?
    assert @rhythm.errors[:opening].present?
    @rhythm.reload
    assert_raises ActiveRecord::RecordInvalid do
      @rhythm.pause!(holder: @user, reason: "x" * 2001)
    end
  end

  test "only creator or account owner manages human holds" do
    outsider = users(:existing_user)
    assert_not @rhythm.manageable_by?(outsider)
    assert_equal :forbidden, @rhythm.pause!(holder: outsider, reason: "No").status
    assert_equal :forbidden, @rhythm.resume!(holder: outsider).status
    assert @rhythm.manageable_by?(@user)
  end

  test "paused resident makes a truthful system hold and release requires correction" do
    @agent.update!(paused: true)
    assert_no_difference "Chat.count" do
      result = @rhythm.fire!(now: @now)
      assert_equal :unavailable, result.status
      assert_match "resident_paused", result.reason
    end
    assert_equal [ "system" ], @rhythm.open_holds.pluck(:kind)
    assert_equal :unavailable, @rhythm.resume!(holder: @user).status
    assert @rhythm.held?
    @agent.update!(paused: false)
    assert_equal :active, @rhythm.resume!(holder: @user).status
  end

  test "removed creator membership prevents scheduled work" do
    memberships(:daniel_personal).update_column(:confirmed_at, nil)
    assert_no_difference "Chat.count" do
      result = @rhythm.fire!(now: @now)
      assert_equal :unavailable, result.status
      assert_equal "creator_not_member", result.reason
    end
  end

  test "accepted guest can be selected and guest removal produces a system hold" do
    guest = agents(:other_account_agent)
    GuestMembership.create!(account: @account, agent: guest, added_by: @user)
    @rhythm.agents = [ guest ]
    @rhythm.save!
    assert_equal [ guest.id ], @rhythm.resident_ids
    @account.guest_memberships.find_by!(agent: guest).destroy!
    assert_equal :unavailable, @rhythm.fire!(now: @now).status
    assert_match "resident_not_present", @rhythm.open_holds.first.reason
  end

  test "cross-account resident without guest membership is rejected" do
    assert_raises ActiveRecord::RecordInvalid do
      @rhythm.agents = [ agents(:other_account_agent) ]
    end
  end

  test "feature flag off refuses visibly rather than accepting an undeliverable room" do
    AgentRuntimeInteraction.stub(:live_activity_enabled?, false) do
      assert_no_difference "Chat.count" do
        result = @rhythm.fire!(now: @now)
        assert_equal :unavailable, result.status
        assert_equal "live_activity_disabled", result.reason
      end
    end
  end

  test "deleting a rhythm retains occurrence snapshots and its room" do
    occurrence = @rhythm.fire!(now: @now).occurrence
    @rhythm.update!(title: "Changed", opening: "Different")
    @rhythm.destroy!
    assert_nil occurrence.reload.rhythm_id
    assert_equal "Morning look — 3 Oct 2026", occurrence.title
    assert_equal "Morning look", occurrence.rhythm_title
    assert_equal "What is taking shape?", occurrence.opening
    assert Chat.exists?(occurrence.chat_id)
    assert Message.exists?(occurrence.message_id)
  end

  test "lost enqueue is accepted once and duplicate manual retry cannot make a new room" do
    MessageDispatchJob.stub(:perform_later, ->(*) { raise "queue unavailable" }) do
      assert_equal :created, @rhythm.fire!(now: @now, manual: true, request_key: "lost").status
    end
    assert_no_difference [ "Chat.count", "MessageDispatch.count" ] do
      assert_equal :duplicate, @rhythm.fire!(now: @now, manual: true, request_key: "lost").status
    end
    assert_equal "pending", @rhythm.occurrences.find_by!(request_key: "lost").message_dispatch.status
  end

  test "unique scheduled and manual identities are database enforced" do
    first = @rhythm.fire!(now: @now).occurrence
    scheduled_duplicate = duplicate_in_another_room(first)
    error = assert_raises ActiveRecord::RecordNotUnique do
      RhythmOccurrence.transaction(requires_new: true) do
        scheduled_duplicate.save!
      end
    end
    assert_match "index_rhythm_occurrences_scheduled_identity", error.message
    manual = @rhythm.fire!(now: @now, manual: true, request_key: "identity").occurrence
    manual_duplicate = duplicate_in_another_room(manual)
    error = assert_raises ActiveRecord::RecordNotUnique do
      RhythmOccurrence.transaction(requires_new: true) do
        manual_duplicate.save!
      end
    end
    assert_match "index_rhythm_occurrences_manual_identity", error.message
  end

  test "failed durable intent rolls back the room occurrence and schedule together" do
    original_next_run = @rhythm.next_run_at
    MessageDispatch.stub(:accept!, ->(**) { raise "intent unavailable" }) do
      assert_no_difference [ "Chat.count", "Message.count", "RhythmOccurrence.count" ] do
        assert_raises(RuntimeError) { @rhythm.fire!(now: @now) }
      end
    end
    assert_equal original_next_run, @rhythm.reload.next_run_at
  end

  private

  def duplicate_in_another_room(occurrence)
    room = @account.chats.create_with_message!(
      { title: "Constraint test", manual_responses: true }, message_content: "Another opening",
      user: @user, agent_ids: [ @agent.id ], automatic_response: false
    )
    occurrence.dup.tap do |duplicate|
      duplicate.chat = room
      duplicate.message = room.messages.first!
    end
  end

end
