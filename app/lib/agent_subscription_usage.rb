class AgentSubscriptionUsage

  PROVIDER_NAMES = {
    "anthropic" => "Claude",
    "gemini" => "Gemini",
    "openai" => "OpenAI",
    "xai" => "Grok"
  }.freeze

  attr_reader :snapshot

  def initialize(snapshot)
    @snapshot = snapshot.to_h.stringify_keys
  end

  def limited?
    snapshot["status"] == "limited"
  end

  def resets_at
    blocking_windows
      .filter_map { |window| Time.zone.parse(window["resets_at"].to_s) if window["resets_at"].present? }
      .select(&:future?)
      .min
  rescue ArgumentError
    nil
  end

  def user_message(time_zone: nil)
    message = "#{provider_name}'s subscription limit has been reached."
    return "#{message} Please try again later." unless resets_at

    "#{message} It should reset #{formatted_reset(time_zone)}."
  end

  private

  def provider_name
    PROVIDER_NAMES.fetch(snapshot["provider"], snapshot["provider"].to_s.titleize.presence || "Provider")
  end

  def blocking_windows
    Array(snapshot["windows"]).filter_map do |window|
      normalized = window.to_h.stringify_keys
      normalized if normalized["blocking"] && normalized["remaining_percent"].to_f <= 0
    end
  end

  def formatted_reset(time_zone)
    zone = time_zone.present? ? ActiveSupport::TimeZone[time_zone] : nil
    zone ||= ActiveSupport::TimeZone["UTC"]
    local_reset = resets_at.in_time_zone(zone)
    local_today = Time.current.in_time_zone(zone).to_date
    time = local_reset.strftime("%-I:%M %p")

    if local_reset.to_date == local_today
      "at #{time}"
    elsif local_reset.to_date == local_today + 1
      "tomorrow at #{time}"
    else
      "on #{local_reset.strftime("%B %-d")} at #{time}"
    end
  end

end
