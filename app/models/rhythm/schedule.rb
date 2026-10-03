# Calendar arithmetic stays local to the rhythm's zone. UTC is only the stored
# instant. TimeZone#local supplies ActiveSupport's gap/fold behavior; we never
# advance a calendar day by adding 24 hours.
class Rhythm::Schedule

  def initialize(rhythm)
    @rhythm = rhythm
    @zone = ActiveSupport::TimeZone[rhythm.timezone]
  end

  def next_occurrence(after:)
    date = period_date(after.in_time_zone(@zone).to_date)
    candidate = local_time(date)
    candidate = local_time(shift(date, 1)) if candidate <= after
    candidate.utc
  end

  def latest_occurrence(at:)
    date = period_date(at.in_time_zone(@zone).to_date)
    candidate = local_time(date)
    candidate = local_time(shift(date, -1)) if candidate > at
    candidate.utc
  end

  private

  def period_date(date)
    case @rhythm.cadence
    when "daily" then date
    when "weekly" then date - ((date.wday - @rhythm.weekday) % 7)
    when "monthly" then clamped_date(date.year, date.month)
    when "yearly" then clamped_date(date.year, @rhythm.month)
    end
  end

  def shift(date, amount)
    case @rhythm.cadence
    when "daily" then date + amount
    when "weekly" then date + 7 * amount
    when "monthly"
      period = Date.new(date.year, date.month, 1) >> amount
      clamped_date(period.year, period.month)
    when "yearly" then clamped_date(date.year + amount, @rhythm.month)
    end
  end

  def clamped_date(year, month)
    Date.new(year, month, [ @rhythm.month_day, Date.new(year, month, -1).day ].min)
  end

  def local_time(date)
    hour, minute = @rhythm.time_of_day.split(":").map(&:to_i)
    @zone.local(date.year, date.month, date.day, hour, minute)
  end

end
