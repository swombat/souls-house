class RhythmPresentation

  include Rails.application.routes.url_helpers

  RECENT_RUNS = 5

  def initialize(rhythm, user: nil, agent: nil)
    @rhythm, @user, @agent = rhythm, user, agent
  end

  def as_json(history: false, recent: false)
    manageable = @rhythm.manageable_by?(@user) || @rhythm.manageable_by_agent?(@agent)
    holds = @rhythm.persisted? ? @rhythm.open_holds.includes(:user, :agent).to_a : []
    at = @rhythm.next_run_at
    selected = @rhythm.agents.to_a
    seat_models = @rhythm.persisted? ? @rhythm.rhythm_agents.pluck(:agent_id, :model_id).to_h : {}
    # A form re-rendered after a rejected save shows what was asked for.
    seat_models = seat_models.merge(@rhythm.pending_resident_models.to_h)
    present = @agent && @rhythm.account.conversation_agents.exists?(@agent.id)
    {
      id: @rhythm.persisted? ? @rhythm.to_param : nil,
      account_id: @rhythm.account.to_param,
      url: @rhythm.persisted? ? account_rhythm_path(@rhythm.account, @rhythm) : nil,
      title: @rhythm.title, opening: @rhythm.opening, append_date: @rhythm.append_date,
      cadence: @rhythm.cadence, time_of_day: @rhythm.time_of_day,
      weekday: @rhythm.weekday, month_day: @rhythm.month_day, month: @rhythm.month,
      timezone: @rhythm.timezone, timezone_identifier: ActiveSupport::TimeZone[@rhythm.timezone.to_s]&.tzinfo&.identifier,
      next_run_at: at&.iso8601,
      preview_title: at ? @rhythm.preview_title(at: at) : @rhythm.title,
      schedule_description: schedule_description, state: holds.empty? ? "active" : "paused",
      creator: {
        id: (@rhythm.creator_agent || @rhythm.creator)&.to_param,
        name: @rhythm.creator_agent&.name || display_name(@rhythm.creator),
        type: @rhythm.creator_agent ? "agent" : (@rhythm.creator ? "user" : nil)
      },
      resident_ids: selected.map(&:to_param),
      # nil follows the resident's default; a model id pins the model the
      # rhythm's conversations open with.
      resident_models: selected.to_h { |resident| [ resident.to_param, seat_models[resident.id] ] },
      residents: selected.map { |resident| resident_payload(resident, seat_models[resident.id]) },
      can_manage: manageable, can_resume: holds.any? { |hold| can_release?(hold) },
      can_join: !!(present && @agent.eligible_for_conversation? && !selected.include?(@agent)),
      can_leave: !!(present && selected.include?(@agent)),
      start_request_key: SecureRandom.uuid, errors: @rhythm.errors.to_hash(true),
      holds: holds.map { |hold| hold_payload(hold) },
      occurrences: history ? @rhythm.occurrences.includes(:chat, message: :message_dispatch)
        .order(created_at: :desc).limit(30).map { |occurrence| occurrence_payload(occurrence) } : [],
      recent_runs: recent ? recent_runs : []
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

  def resident_payload(resident, model_id)
    {
      id: resident.to_param, name: resident.name, colour: resident.colour,
      model_id: model_id, model_label: Agent.label_for_model(model_id.presence || resident.model_id),
      model_selected: model_id.present?
    }
  end

  # The last few conversations, shown inline on the Rhythms page. Quiet runs
  # are off the conversation list (Chat::QuietRhythmRun), so this is where
  # they are seen; `listed` says a run has been brought into the list.
  def recent_runs
    return [] unless @rhythm.persisted?

    occurrences = @rhythm.occurrences.joins(:chat).merge(Chat.kept).includes(:chat)
      .order(created_at: :desc).limit(RECENT_RUNS).to_a
    quiet = Chat.quiet_rhythm_runs.where(id: occurrences.map(&:chat_id)).pluck(:id).to_set
    occurrences.map do |occurrence|
      chat = occurrence.chat
      { id: occurrence.id.to_s, title: chat.title_or_default, scheduled_for: occurrence.scheduled_for.iso8601,
        chat_url: account_chat_path(@rhythm.account, chat), listed: !quiet.include?(chat.id) }
    end
  end

  # Names can be blank for people who never filled in a profile.
  def display_name(user)
    return unless user

    user.full_name.presence || user.email_address.to_s.split("@").first
  end

  def can_release?(hold)
    return hold.agent == @agent if hold.kind == "agent"
    return true if @rhythm.manageable_by?(@user)

    hold.kind == "system" && @rhythm.manageable_by_agent?(@agent)
  end

  def hold_payload(hold)
    {
      id: hold.id.to_s, holder_type: hold.kind,
      holder_name: hold.kind == "system" ? "System" : (hold.agent&.name || display_name(hold.user)),
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
    names = dispatch.chat.agents.to_h { |resident| [ resident.to_param, resident.name ] }
    runs = data[:runs].map { |run| "#{names[run[:agent_id]] || 'Former resident'}: #{run[:status]}" }
    ([ dispatch.status, dispatch.reason ] + runs).compact_blank.join(" · ")
  end

end
