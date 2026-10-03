class RhythmPresentation

  include Rails.application.routes.url_helpers

  def initialize(rhythm, user: nil, agent: nil)
    @rhythm, @user, @agent = rhythm, user, agent
  end

  def as_json(history: false)
    manageable = @rhythm.manageable_by?(@user)
    holds = @rhythm.persisted? ? @rhythm.open_holds.includes(:user, :agent).to_a : []
    at = @rhythm.next_run_at
    {
      id: @rhythm.persisted? ? @rhythm.to_param : nil,
      title: @rhythm.title, opening: @rhythm.opening, append_date: @rhythm.append_date,
      cadence: @rhythm.cadence, time_of_day: @rhythm.time_of_day,
      weekday: @rhythm.weekday, month_day: @rhythm.month_day, month: @rhythm.month,
      timezone: @rhythm.timezone, next_run_at: at&.iso8601,
      preview_title: at ? @rhythm.preview_title(at: at) : @rhythm.title,
      schedule_description: schedule_description, state: holds.empty? ? "active" : "paused",
      creator: { id: @rhythm.creator&.to_param, name: @rhythm.creator&.full_name },
      resident_ids: @rhythm.agents.map(&:to_param),
      residents: @rhythm.agents.map { |resident| { id: resident.to_param, name: resident.name, colour: resident.colour } },
      can_manage: manageable, can_resume: holds.any? { |hold| can_release?(hold) },
      start_request_key: SecureRandom.uuid, errors: @rhythm.errors.to_hash(true),
      holds: holds.map { |hold| hold_payload(hold) },
      occurrences: history ? @rhythm.occurrences.includes(:chat, message: :message_dispatch)
        .order(created_at: :desc).limit(30).map { |occurrence| occurrence_payload(occurrence) } : []
    }
  end

  def schedule_description
    day = @rhythm.month_day
    cadence = case @rhythm.cadence
    when "daily" then "Every day"
    when "weekly" then "Every #{Date::DAYNAMES[@rhythm.weekday.to_i % 7]}"
    when "monthly" then "Monthly on day #{day} (last day if shorter)"
    when "yearly" then "Every #{Date::MONTHNAMES[@rhythm.month.to_i.clamp(1, 12)]} #{day} (last day if shorter)"
    else "Choose a schedule"
    end
    "#{cadence} at #{@rhythm.time_of_day} · #{@rhythm.timezone}"
  end

  private

  def can_release?(hold)
    hold.kind == "agent" ? hold.agent == @agent : @rhythm.manageable_by?(@user)
  end

  def hold_payload(hold)
    {
      id: hold.id.to_s, holder_type: hold.kind,
      holder_name: hold.agent&.name || hold.user&.full_name || "System",
      reason: hold.reason, created_at: hold.created_at.iso8601, can_release: can_release?(hold)
    }
  end

  def occurrence_payload(occurrence)
    dispatch = occurrence.message&.message_dispatch
    {
      id: occurrence.id.to_s, title: occurrence.title, scheduled_for: occurrence.scheduled_for.iso8601,
      created_at: occurrence.created_at.iso8601, manual: occurrence.manual,
      late: !occurrence.manual && occurrence.created_at > occurrence.scheduled_for + 15.minutes,
      chat_url: occurrence.chat && account_chat_path(occurrence.chat.account, occurrence.chat),
      status: dispatch ? dispatch_status(dispatch) : "Conversation created; no activation recorded"
    }
  end

  def dispatch_status(dispatch)
    data = dispatch.as_app_json
    runs = data[:runs].map { |run| "#{run[:agent_id]}: #{run[:status]}" }
    ([ dispatch.status, dispatch.reason ] + runs).compact_blank.join(" · ")
  end

end
