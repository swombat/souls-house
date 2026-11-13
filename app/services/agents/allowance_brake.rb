# All admission/claim checks are database-only, even under row locks. Usage
# refresh is coalesced durably and runs after commit, outside scheduler locks.
class Agents::AllowanceBrake

  FRESH_FOR = 60.seconds
  REFRESH_EVERY = 2.minutes
  Result = Struct.new(:status, :checked_at, :remaining_percent, keyword_init: true) do
    def braked? = status.in?(%w[braked braked_stale])
    def as_json(*) = { status: status, checked_at: checked_at&.iso8601, remaining_percent: remaining_percent }
  end

  def self.manageable_by?(account, user)
    user.present? && account.ai_credentials_manageable_by?(user)
  end

  def self.check(agent, model_id: nil, essential: false, refresh: true, notify: true)
    return Result.new(status: "disabled") if agent.allowance_brake_threshold_percent.nil?
    return Result.new(status: "essential") if essential
    new(agent, model_id: model_id).check(essential: essential, refresh: refresh, notify: notify)
  rescue KeyError, ArgumentError
    Result.new(status: "unavailable")
  end

  def self.rhythm_reason(rhythm, human_requested: false, chat: nil)
    return if human_requested
    return unless rhythm
    models = rhythm.resident_models
    rhythm.agents.order(:id).each do |agent|
      model_id = chat ? Agents::ModelSelection.for(agent, chat: chat).model_id : models[agent.id]
      return "skipped_allowance" if check(agent, model_id: model_id, essential: essential_for?(rhythm, agent)).braked?
    end
    nil
  end

  def self.commitment_reason(commitment, chat: nil)
    model_id = chat && Agents::ModelSelection.for(commitment.agent, chat: chat).model_id
    "skipped_allowance" if check(commitment.agent, model_id: model_id,
      essential: essential_for?(commitment, commitment.agent)).braked?
  end

  # Hosting a guest's work does not confer authority over its home budget.
  def self.essential_for?(work, agent)
    work.essential? && work.account_id == agent.account_id
  end

  def self.pending_wake_reason(wake)
    return unless wake.standing_source_kinds == [ "scheduled" ]
    commitments = Commitment.where(pending_wake_id: wake.id, status: "activated")
    return if commitments.empty? || commitments.where(essential: true, account_id: wake.agent.account_id).exists?
    model_id = Agents::ModelSelection.for(wake.agent, chat: wake.chat).model_id
    "skipped_allowance" if check(wake.agent, model_id: model_id).braked?
  end

  def self.interaction_reason(interaction)
    if interaction.trigger_kind == "wake"
      return "skipped_allowance" if check(interaction.agent, essential: interaction.agent.scheduled_wakes_essential?).braked?
    elsif (wake = interaction.released_pending_wake)
      return pending_wake_reason(wake)
    elsif (commitment = Commitment.find_by(wake_interaction_id: interaction.id))
      return commitment_reason(commitment, chat: interaction.chat)
    end
    nil
  end

  # Scheduler preflight, deliberately before taking rhythm/commitment locks.
  # Later claim checks never call this. A failed probe retains the last evidence.
  def self.prepare(agent, model_id: nil, essential: false)
    return if essential || agent.allowance_brake_threshold_percent.nil?
    policy = new(agent, model_id: model_id)
    return unless agent.provider_auth_mode(policy.provider) == "oauth_account"
    reading = AllowanceBrakeReading.create_or_find_by!(agent: agent, provider: policy.provider, model: policy.model)
    return if reading.checked_at && reading.checked_at >= FRESH_FOR.ago
    claimed = AllowanceBrakeReading.where(id: reading.id)
      .where("refresh_requested_at IS NULL OR refresh_requested_at < ?", REFRESH_EVERY.ago)
      .update_all(refresh_requested_at: Time.current)
    refresh!(reading) if claimed == 1
  rescue AgentProviderAuthClient::Error => error
    Rails.logger.info("[AllowanceBrake] preflight unavailable agent=#{agent.id} #{error.class}")
  end

  attr_reader :provider, :model

  def initialize(agent, model_id: nil)
    @agent = agent
    selection = Agents::Sandbox.chaos_selection_for(agent, model_id: model_id.presence || agent.model_id)
    @provider, @model = selection.values_at(:provider, :model)
  end

  def check(essential:, refresh:, notify:)
    return Result.new(status: "disabled") if @agent.allowance_brake_threshold_percent.nil?
    return Result.new(status: "essential") if essential
    return Result.new(status: "unavailable") unless @agent.provider_auth_mode(@provider) == "oauth_account"

    reading = AllowanceBrakeReading.find_by(agent: @agent, provider: @provider, model: @model)
    request_refresh(reading) if refresh && (!reading&.checked_at || reading.checked_at < FRESH_FOR.ago)
    windows = Array(reading&.windows).reject do |window|
      window["resets_at"] && Time.iso8601(window["resets_at"]) <= Time.current
    end
    fresh = reading&.checked_at && reading.checked_at >= FRESH_FOR.ago &&
      reading.observed_at && reading.observed_at.between?(FRESH_FOR.ago, Time.current)
    low = windows.select { |window| window["remaining_percent"] < @agent.allowance_brake_threshold_percent }
    # A reset that has passed cannot support a verdict even if just fetched.
    low.select! { |window| window["resets_at"].nil? || Time.iso8601(window["resets_at"]) > Time.current } if fresh
    low.select! { |window| window["resets_at"] && Time.iso8601(window["resets_at"]) > Time.current } unless fresh
    if low.any?
      low.each { |window| AllowanceBrakeNotice.record!(agent: @agent, provider: @provider, window: window) } if notify
      Result.new(status: fresh ? "braked" : "braked_stale", checked_at: reading.checked_at,
        remaining_percent: low.map { |window| window["remaining_percent"] }.min)
    else
      Result.new(status: fresh && windows.any? ? "available" : "unavailable", checked_at: reading&.checked_at,
        remaining_percent: fresh ? windows.map { |window| window["remaining_percent"] }.min : nil)
    end
  end

  # Called only by the refresh job; never from a locked policy check.
  def self.refresh!(reading)
    snapshot = AgentProviderAuthClient.new(reading.agent).usage(provider: reading.provider, model: reading.model, refresh: true)
    return unless snapshot.is_a?(Hash) && snapshot["status"].in?(%w[available limited]) &&
      snapshot["provider"] == reading.provider && snapshot["model"] == reading.model
    observed = parse_time(snapshot["observed_at"])
    return unless observed && observed <= Time.current
    return unless snapshot["windows"].is_a?(Array) && snapshot["windows"].all? { |window| window.is_a?(Hash) }
    windows = snapshot["windows"].filter_map do |window|
      next unless window["blocking"] == true
      if reading.provider == "openai"
        next unless window["label"].to_s.downcase.include?("codex-spark") == reading.model.downcase.include?("codex-spark")
      end
      raw = window["remaining_percent"]
      return unless raw.is_a?(Numeric)
      value = Float(raw, exception: false)
      return unless value&.finite? && value.between?(0, 100)
      reset = parse_time(window["resets_at"])
      return if window["resets_at"].present? && !reset
      { "id" => window["id"].to_s, "remaining_percent" => value, "resets_at" => reset&.iso8601 }
    end
    # An unsuccessful/unknown response must not erase known low evidence.
    return if windows.empty? || !observed
    reading.with_lock do
      return if reading.observed_at && reading.observed_at > observed
      reading.update!(windows: windows, observed_at: observed, checked_at: Time.current)
    end
  end

  def self.parse_time(value)
    Time.iso8601(value.to_s)
  rescue ArgumentError
    nil
  end

  private

  def request_refresh(reading)
    reading ||= AllowanceBrakeReading.create_or_find_by!(agent: @agent, provider: @provider, model: @model)
    claimed = AllowanceBrakeReading.where(id: reading.id)
      .where("refresh_requested_at IS NULL OR refresh_requested_at < ?", REFRESH_EVERY.ago)
      .update_all(refresh_requested_at: Time.current)
    return unless claimed == 1
    ActiveRecord.after_all_transactions_commit { RefreshAllowanceBrakeJob.perform_later(reading.id) }
  end

end
