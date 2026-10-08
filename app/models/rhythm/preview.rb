# The schedule preview shown while a rhythm is being written: when it would
# next run and what that conversation would be called. Needs neither an
# opening nor a resident selection, and saves nothing.
class Rhythm::Preview

  ATTRIBUTES = %i[title append_date cadence time_of_day weekday month_day month timezone].freeze

  def initialize(account:, attributes:, creator: nil, creator_agent: nil)
    @rhythm = Rhythm.new(attributes)
    @rhythm.account = account
    @rhythm.creator = creator
    @rhythm.creator_agent = creator_agent
  end

  def valid?
    @rhythm.valid?(:preview)
  end

  def errors
    @rhythm.errors.to_hash(true)
  end

  def as_json(*)
    at = @rhythm.next_occurrence(after: Time.current)
    { next_run_at: at.iso8601, preview_title: @rhythm.preview_title(at: at),
      timezone_identifier: ActiveSupport::TimeZone[@rhythm.timezone].tzinfo.identifier,
      schedule_description: RhythmPresentation.new(@rhythm).schedule_description }
  end

end
