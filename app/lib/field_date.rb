# The date an imported Field item is from: recorded_at on a recording,
# dated_at on a file or note. Two shapes are accepted:
#
#   2019-03-14                     a day, midnight in the app's zone
#   2019-03-14T09:30[:00[.5]]      a time, with Z or an offset (+02, +0200,
#                                  +02:00), or without one (the app's zone)
#
# Every component is checked, so an impossible value is refused rather than
# rolled over (Feb 30 is not Mar 2) or cut back to its date (25:99 is not
# midnight). An import from the past has to land on the day it says, or not
# at all.
module FieldDate

  class Invalid < StandardError; end

  DAY = /\A(\d{4})-(\d{2})-(\d{2})\z/
  MOMENT = /\A(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})(?::(\d{2})(\.\d{1,9})?)?(?:(Z)|([+-])(\d{2})(?::?(\d{2}))?)?\z/

  def self.parse(value, param:)
    text = value.to_s.strip
    if (day = DAY.match(text))
      date(day[1], day[2], day[3], param).in_time_zone
    elsif (at = MOMENT.match(text))
      moment(at, param)
    else
      invalid!(param)
    end
  end

  # For an update: blank clears the date, anything else must parse.
  def self.parse_or_clear(value, param:)
    value.blank? ? nil : parse(value, param:)
  end

  def self.moment(at, param)
    year, month, day, hour, minute, second, fraction, zulu, sign, offset_hours, offset_minutes = at.captures
    date = date(year, month, day, param)
    hour, minute, second = hour.to_i, minute.to_i, second.to_i
    invalid!(param) unless hour < 24 && minute < 60 && second < 60
    seconds = second + (fraction ? Rational(fraction.delete("."), 10**(fraction.length - 1)) : 0)

    if zulu || sign
      offset_hours, offset_minutes = offset_hours.to_i, offset_minutes.to_i
      invalid!(param) unless offset_hours < 24 && offset_minutes < 60
      offset = zulu ? 0 : (sign == "-" ? -1 : 1) * (offset_hours * 3600 + offset_minutes * 60)
      Time.new(date.year, date.month, date.day, hour, minute, seconds, offset).in_time_zone
    else
      Time.zone.local(date.year, date.month, date.day, hour, minute, seconds)
    end
  end
  private_class_method :moment

  def self.date(year, month, day, param)
    Date.new(year.to_i, month.to_i, day.to_i)
  rescue Date::Error
    invalid!(param)
  end
  private_class_method :date

  def self.invalid!(param)
    raise Invalid, "#{param} must be an ISO 8601 date (2019-03-14) or time (2019-03-14T09:30:00Z)"
  end
  private_class_method :invalid!

end
