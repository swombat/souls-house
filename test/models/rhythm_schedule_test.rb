require "test_helper"

class RhythmScheduleTest < ActiveSupport::TestCase

  test "daily slots use the effective array with strict next and inclusive latest" do
    schedule = daily_schedule("09:00", "17:00")
    morning = Time.utc(2026, 11, 23, 8)
    evening = Time.utc(2026, 11, 23, 16)

    assert_equal morning, schedule.next_occurrence(after: morning - 1)
    assert_equal morning, schedule.latest_occurrence(at: morning)
    assert_equal evening, schedule.next_occurrence(after: morning)
    assert_equal morning, schedule.latest_occurrence(at: evening - 1)
    assert_equal evening, schedule.latest_occurrence(at: evening)
    assert_predicate schedule.next_occurrence(after: morning), :utc?
  end

  test "daily slots cross local midnight using adjacent calendar dates" do
    schedule = daily_schedule("00:00", "23:30")
    midnight = Time.utc(2026, 11, 22, 23)
    previous = Time.utc(2026, 11, 22, 22, 30)
    evening = Time.utc(2026, 11, 23, 22, 30)

    assert_equal previous, schedule.latest_occurrence(at: midnight - 1)
    assert_equal midnight, schedule.next_occurrence(after: midnight - 1)
    assert_equal midnight, schedule.latest_occurrence(at: midnight)
    assert_equal evening, schedule.next_occurrence(after: midnight)
    assert_equal midnight, schedule.latest_occurrence(at: evening - 1)
    assert_equal Time.utc(2026, 11, 23, 23), schedule.next_occurrence(after: evening)
  end

  test "Madrid gap slots are ordered by resolved instant rather than wall clock" do
    schedule = daily_schedule("02:45", "03:15")
    early = Time.utc(2026, 3, 29, 1, 15)
    late = Time.utc(2026, 3, 29, 1, 45)

    assert_equal early, schedule.next_occurrence(after: Time.utc(2026, 3, 29))
    assert_equal early, schedule.latest_occurrence(at: early)
    assert_equal late, schedule.next_occurrence(after: early)
    assert_equal early, schedule.latest_occurrence(at: late - 1)
    assert_equal late, schedule.latest_occurrence(at: late)
    assert_equal Time.utc(2026, 3, 30, 0, 45), schedule.next_occurrence(after: late)
  end

  test "Madrid gap collisions produce a single occurrence" do
    schedule = daily_schedule("02:30", "03:30")
    collision = Time.utc(2026, 3, 29, 1, 30)

    assert_equal collision, schedule.next_occurrence(after: collision - 1)
    assert_equal collision, schedule.latest_occurrence(at: collision)
    assert_equal Time.utc(2026, 3, 30, 0, 30), schedule.next_occurrence(after: collision)
    assert_equal collision, schedule.latest_occurrence(at: Time.utc(2026, 3, 29, 22))
    candidates = schedule.send(:daily_candidates, collision)
    assert_equal candidates.uniq.sort, candidates
  end

  test "Madrid fold resolves each wall time once on the daylight side" do
    schedule = daily_schedule("02:15", "02:45")
    early = Time.utc(2026, 10, 25, 0, 15)
    late = Time.utc(2026, 10, 25, 0, 45)

    assert_equal early, schedule.next_occurrence(after: Time.utc(2026, 10, 25))
    assert_equal late, schedule.next_occurrence(after: early)
    assert_equal late, schedule.latest_occurrence(at: late)
    assert_equal late, schedule.latest_occurrence(at: Time.utc(2026, 10, 25, 1, 30))
    assert_equal Time.utc(2026, 10, 26, 1, 15), schedule.next_occurrence(after: late)
    assert_equal Time.utc(2026, 10, 26, 1, 15), schedule.next_occurrence(after: Time.utc(2026, 10, 25, 1, 30))
  end

  test "non daily cadences retain their single time and calendar clamping" do
    [
      [ { cadence: "weekly", weekday: 1 }, Time.utc(2026, 11, 23, 8), Time.utc(2026, 11, 30, 8) ],
      [ { cadence: "monthly", month_day: 31 }, Time.utc(2027, 2, 28, 8), Time.utc(2027, 3, 31, 7) ],
      [ { cadence: "yearly", month: 2, month_day: 29 }, Time.utc(2027, 2, 28, 8), Time.utc(2028, 2, 29, 8) ]
    ].each do |attributes, current, following|
      rhythm = Rhythm.new(**attributes, timezone: "Madrid", time_of_day: "09:00")
      schedule = Rhythm::Schedule.new(rhythm)

      assert_equal current, schedule.next_occurrence(after: current - 1)
      assert_equal current, schedule.latest_occurrence(at: current)
      assert_equal following, schedule.next_occurrence(after: current)
      assert_equal current, schedule.latest_occurrence(at: following - 1)
    end
  end

  private

  def daily_schedule(*times)
    rhythm = Rhythm.new(cadence: "daily", timezone: "Madrid", times_of_day: times)
    Rhythm::Schedule.new(rhythm)
  end

end
