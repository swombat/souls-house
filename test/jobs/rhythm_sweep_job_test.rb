require "test_helper"

class RhythmSweepJobTest < ActiveSupport::TestCase

  setup do
    @now = Time.utc(2026, 10, 3, 10)
    @agent = agents(:research_assistant)
    @rhythm = Rhythm.create!(
      account: @agent.account, creator: users(:user_1), title: "Weekly",
      opening: "A weekly look", cadence: "weekly", weekday: 6, time_of_day: "09:00",
      timezone: "UTC", agents: [ @agent ], next_run_at: @now - 14.days
    )
  end

  test "repeated sweeps create latest missed only and advance into the future" do
    travel_to @now do
      assert_difference "RhythmOccurrence.count", 1 do
        2.times { RhythmSweepJob.perform_now }
      end
      assert_equal Time.utc(2026, 10, 3, 9), @rhythm.occurrences.first.scheduled_for
      assert_equal Time.utc(2026, 10, 10, 9), @rhythm.reload.next_run_at
    end
  end

  test "held rhythms are not fired" do
    @rhythm.pause!(holder: users(:user_1), reason: "Not now")
    travel_to @now do
      assert_no_difference "Chat.count" do
        RhythmSweepJob.perform_now
      end
    end
  end

  test "a failing rhythm does not prevent another due rhythm from firing" do
    calls = []
    failing = Object.new
    failing.define_singleton_method(:id) { 0 }
    failing.define_singleton_method(:fire!) { |**| raise "one bad row" }
    working = Object.new
    working.define_singleton_method(:fire!) { |**| calls << :worked }
    scope = Object.new
    scope.define_singleton_method(:find_each) { |&block| [ failing, working ].each(&block) }
    Rhythm.stub(:due, scope) { RhythmSweepJob.perform_now }
    assert_equal [ :worked ], calls
  end

end
