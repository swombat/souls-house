class ResidentSessionActivityReport

  DEFAULT_WINDOW = "24h"
  WINDOWS = {
    "1h" => 1.hour,
    "24h" => 24.hours,
    "7d" => 7.days
  }.freeze
  CHANNEL_ORDER = %w[web telegram wake orientation memory other].freeze

  attr_reader :now, :window, :time_zone

  def initialize(now: Time.current, window: DEFAULT_WINDOW, time_zone: "UTC", channel: nil)
    @now = now
    @window = WINDOWS.key?(window) ? window : DEFAULT_WINDOW
    @time_zone = ActiveSupport::TimeZone[time_zone] || ActiveSupport::TimeZone["UTC"]
    @channel = channel if CHANNEL_ORDER.include?(channel)
  end

  def call
    stored_week_rows = interactions_since(week_started_at)
    week_rows = stored_week_rows.reject(&:session_busy?)
    stored_visible_rows = stored_week_rows.select { |row| row.started_at >= window_started_at }
    if channel.present?
      stored_visible_rows.select! { |row| channel_for(row.trigger_kind) == channel }
    end
    visible_busy_retries = stored_visible_rows.count(&:session_busy?)
    visible_rows = stored_visible_rows.reject(&:session_busy?)
    sessions = sessions_for(visible_rows)

    {
      generated_at: now.utc.iso8601,
      time_zone: time_zone.name,
      window: window,
      window_started_at: window_started_at.utc.iso8601,
      selected_channel: channel,
      channel_options: channel_options_for(week_rows),
      summary: summary_for(visible_rows, sessions).merge(
        busy_retries: visible_busy_retries
      ),
      activity: {
        started_at: week_started_at.iso8601,
        days: activity_days_for(week_rows)
      },
      sessions: sessions
    }
  end

  private

  attr_reader :channel

  def interactions_since(started_at)
    AgentRuntimeInteraction
      .includes(:chat, agent: :account)
      .where(started_at: started_at..now)
      .order(:started_at, :id)
      .to_a
  end

  def window_started_at
    @window_started_at ||= now - WINDOWS.fetch(window)
  end

  def week_started_at
    @week_started_at ||= begin
      date = now.in_time_zone(time_zone).to_date - 6
      time_zone.local(date.year, date.month, date.day).utc
    end
  end

  def sessions_for(interactions)
    interactions
      .group_by { |row| [ row.agent_id, logical_session_id(row) ] }
      .map { |(_agent_id, session_id), rows| session_json(session_id, rows) }
      .sort_by { |session| session[:last_observed_at] }
      .reverse
  end

  def session_json(session_id, interactions)
    latest = interactions.max_by { |row| [ row.started_at, row.id ] }
    first_started_at = interactions.filter_map(&:started_at).min
    last_observed_at = interactions.filter_map { |row| row.finished_at || row.started_at }.max
    agent = latest.agent

    {
      session_id: session_id,
      resident: {
        id: agent.to_param,
        name: agent.name,
        runtime: agent.runtime,
        account_id: agent.account.to_param,
        account_name: agent.account.name
      },
      channel: channel_for(latest.trigger_kind),
      channel_label: channel_label(channel_for(latest.trigger_kind)),
      trigger_kinds: interactions.filter_map(&:trigger_kind).uniq,
      status: status_for(interactions, latest),
      conversation_id: interactions.filter_map(&:conversation_obfuscated_id).first,
      conversation_title: interactions.filter_map { |row| row.chat&.title_or_default }.first,
      first_observed_at: first_started_at.utc.iso8601,
      last_observed_at: last_observed_at.utc.iso8601,
      active_duration_ms: ((last_observed_at - first_started_at) * 1000).round,
      interaction_count: interactions.size,
      chaos_process_count: interactions.filter_map(&:chaos_session_id).uniq.size,
      provider: interactions.reverse_each.find { |row| row.provider.present? }&.provider,
      model: interactions.reverse_each.find { |row| row.model.present? }&.model,
      estimated_cost: estimated_cost_for(interactions),
      latest_outcome: latest.session_outcome,
      latest_error: latest.error_message.present? || latest.transport_status.to_i >= 400 ||
        latest.runtime_returncode.to_i.nonzero?
    }
  end

  def status_for(interactions, latest)
    return "running" if interactions.any? { |row| active_at?(row) }
    return "stale" if latest.finished_at.nil?
    return "failed" if latest.error_message.present? || latest.transport_status.to_i >= 400 ||
      latest.runtime_returncode.to_i.nonzero?

    "completed"
  end

  def active_at?(interaction)
    interaction.finished_at.nil? &&
      interaction.started_at.present? &&
      interaction.started_at >= now - AgentRuntimeInteraction::ACTIVE_WINDOW
  end

  def summary_for(interactions, sessions)
    {
      running_sessions: sessions.count { |session| session[:status] == "running" },
      active_residents: interactions.map(&:agent_id).uniq.size,
      sessions: sessions.size,
      interactions: interactions.size,
      channels: interactions.group_by { |row| channel_for(row.trigger_kind) }.transform_values(&:size)
    }
  end

  def activity_days_for(interactions)
    rows_by_date = interactions.group_by { |row| row.started_at.in_time_zone(time_zone).to_date }

    (0..6).map do |days_ago|
      date = now.in_time_zone(time_zone).to_date - (6 - days_ago)
      rows = rows_by_date.fetch(date, [])

      {
        date: date.iso8601,
        label: date.strftime("%a"),
        interactions: rows.size,
        sessions: rows.map { |row| [ row.agent_id, logical_session_id(row) ] }.uniq.size,
        residents: rows.map(&:agent_id).uniq.size,
        channels: rows.group_by { |row| channel_for(row.trigger_kind) }.transform_values(&:size),
        buckets: activity_buckets_for(date, rows)
      }
    end
  end

  def activity_buckets_for(date, interactions)
    rows_by_hour = interactions.group_by do |row|
      local = row.started_at.in_time_zone(time_zone)
      local.hour - (local.hour % 2)
    end

    (0...24).step(2).map do |hour|
      rows = rows_by_hour.fetch(hour, [])
      started_at = time_zone.local(date.year, date.month, date.day, hour)

      {
        started_at: started_at.utc.iso8601,
        label: started_at.strftime("%H:%M"),
        interactions: rows.size,
        sessions: rows.map { |row| [ row.agent_id, logical_session_id(row) ] }.uniq.size,
        residents: rows.map(&:agent_id).uniq.size,
        channels: rows.group_by { |row| channel_for(row.trigger_kind) }.transform_values(&:size)
      }
    end
  end

  def estimated_cost_for(interactions)
    costs = interactions.map(&:estimated_cost)
    amounts = costs.filter_map { |cost| cost[:amount_usd] }
    status = if amounts.empty?
      "unavailable"
    elsif amounts.size == interactions.size
      "estimated"
    else
      "partial"
    end

    {
      status: status,
      amount_usd: amounts.any? ? amounts.sum { |amount| BigDecimal(amount) }.to_s("F") : nil,
      basis: cost_basis_for(interactions),
      priced_interactions: amounts.size,
      interaction_count: interactions.size
    }
  end

  def cost_basis_for(interactions)
    subscription_rows = interactions.count(&:subscription_based?)
    return "subscription_equivalent" if subscription_rows == interactions.size
    return "api" if subscription_rows.zero?

    "mixed"
  end

  def channel_options_for(interactions)
    present = interactions.map { |row| channel_for(row.trigger_kind) }.uniq
    CHANNEL_ORDER.filter_map do |value|
      { value: value, label: channel_label(value) } if present.include?(value)
    end
  end

  def channel_for(trigger_kind)
    case trigger_kind
    when "conversation" then "web"
    when "telegram" then "telegram"
    when "wake" then "wake"
    when "orientation" then "orientation"
    when /\Amemory_aggregation_/ then "memory"
    else "other"
    end
  end

  def channel_label(value)
    {
      "web" => "Web chat",
      "telegram" => "Telegram",
      "wake" => "Wake",
      "orientation" => "Orientation",
      "memory" => "Memory",
      "other" => "Other"
    }.fetch(value)
  end

  def logical_session_id(interaction)
    interaction.session_id.presence || "interaction-#{interaction.id}"
  end

end
