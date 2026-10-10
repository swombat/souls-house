# The date an imported Field item is from: recorded_at on a recording,
# dated_at on a file or note. ISO 8601, a date or a time. Anything else is
# refused rather than silently stored as nothing.
module FieldDate

  class Invalid < StandardError; end

  def self.parse(value, param:)
    Time.iso8601(value.to_s)
  rescue ArgumentError
    begin
      Date.iso8601(value.to_s).in_time_zone
    rescue Date::Error
      raise Invalid, "#{param} must be an ISO 8601 date or time"
    end
  end

  # For an update: blank clears the date, anything else must parse.
  def self.parse_or_clear(value, param:)
    value.blank? ? nil : parse(value, param:)
  end

end
