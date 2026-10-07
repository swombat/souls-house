class Rhythm < ApplicationRecord

  include ObfuscatesId

  Result = Struct.new(:status, :occurrence, :reason, keyword_init: true) do
    def created? = status == :created
    def duplicate? = status == :duplicate
    def success? = status.in?(%i[created duplicate active held])
  end

  SCHEDULE_FIELDS = %w[cadence time_of_day weekday month_day month timezone].freeze

  belongs_to :account
  belongs_to :creator, class_name: "User", optional: true
  belongs_to :creator_agent, class_name: "Agent", optional: true
  has_many :rhythm_agents, dependent: :destroy
  has_many :agents, through: :rhythm_agents
  has_many :holds, class_name: "RhythmHold", dependent: :destroy
  has_many :open_holds, -> { open }, class_name: "RhythmHold"
  has_many :occurrences, class_name: "RhythmOccurrence", dependent: :nullify

  enum :cadence, %w[daily weekly monthly yearly].index_with(&:itself), validate: true

  validates :title, :time_of_day, :timezone, :next_run_at, presence: true
  validates :opening, presence: true, unless: -> { validation_context == :preview }
  validates :title, length: { maximum: 255 }
  validates :opening, length: { maximum: 20_000 }
  validates :time_of_day, format: { with: /\A(?:[01]\d|2[0-3]):[0-5]\d\z/ }
  validates :timezone, inclusion: { in: ActiveSupport::TimeZone.all.map(&:name) }
  validates :weekday, inclusion: { in: 0..6 }, if: :weekly?
  validates :month_day, inclusion: { in: 1..31 }, if: -> { monthly? || yearly? }
  validates :month, inclusion: { in: 1..12 }, if: :yearly?
  validates :append_date, inclusion: { in: [ true, false ] }
  validates :agents, length: { minimum: 1 }, on: :create, unless: -> { validation_context == :preview }
  validate :one_creator
  validate :residents_present_in_account, if: :new_record?

  before_validation :reset_next_run, if: :schedule_changed?
  after_save :hold_empty_selection

  scope :due, ->(now = Time.current) { where(next_run_at: ..now) }

  def resident_ids = agent_ids

  def resident_ids=(ids)
    self.agent_ids = ids
  end

  def manageable_by?(user)
    user.present? && (creator_id == user.id || account.owned_by?(user))
  end

  def manageable_by_agent?(agent)
    agent.present? && creator_agent_id == agent.id && account.conversation_agents.exists?(agent.id)
  end

  def join!(agent:)
    with_lock do
      next Result.new(status: :forbidden) unless account.conversation_agents.exists?(agent.id)
      agent.require_conversation_runtime!
      rhythm_agents.find_or_create_by!(agent: agent)
      Result.new(status: held? ? :held : :active)
    end
  end

  def leave!(agent:)
    with_lock do
      rhythm_agents.where(agent: agent).destroy_all
      # Never remove a departing resident's holds, nor delete their invitation.
      add_system_hold!("no_selected_residents") unless agents.reload.exists?
      Result.new(status: held? ? :held : :active)
    end
  end

  def held?
    open_holds.exists?
  end

  def next_occurrence(after: Time.current)
    Rhythm::Schedule.new(self).next_occurrence(after: after)
  end

  def preview_title(at: Time.current)
    append_date? ? "#{title} — #{at.in_time_zone(timezone).strftime('%-d %b %Y')}" : title
  end

  # The rhythm row lock protects both schedule advancement and manual request
  # identity. The database indexes are a second guard. Re-delivery of a sweep
  # never creates another room for the same scheduled instant.
  def fire!(now: Time.current, manual: false, request_key: nil)
    if manual && (!request_key.is_a?(String) || request_key.blank? || request_key.length > 128)
      return Result.new(status: :invalid_request, reason: "A manual start requires a request key of at most 128 characters")
    end

    occurrence = nil
    result = with_lock do
      if manual && (existing = occurrences.find_by(manual: true, request_key: request_key))
        next Result.new(status: :duplicate, occurrence: existing)
      end
      next Result.new(status: :held, reason: "This rhythm has open holds") if held?
      next Result.new(status: :not_due) unless manual || next_run_at <= now

      if (reason = unavailable_reason)
        add_system_hold!(reason)
        next Result.new(status: :unavailable, reason: reason)
      end

      scheduled_for = manual ? now : Rhythm::Schedule.new(self).latest_occurrence(at: now)
      # An explicit next_run_at may be later than the calendar's previous slot.
      scheduled_for = [ scheduled_for, next_run_at ].max unless manual
      if !manual && (existing = occurrences.find_by(manual: false, scheduled_for: scheduled_for))
        update!(next_run_at: next_occurrence(after: now))
        next Result.new(status: :duplicate, occurrence: existing)
      end

      occurrence_title = preview_title(at: scheduled_for)
      chat = account.chats.create_with_message!(
        { title: occurrence_title, manual_responses: true },
        message_content: creator_agent ? nil : opening, user: creator, agent_ids: agents.order(:id).ids,
        automatic_response: false
      )
      if creator_agent
        chat.messages.create!(role: "assistant", agent: creator_agent, content: opening,
          suppress_automatic_dispatch: true)
      end
      message = chat.messages.first!
      MessageDispatch.accept!(message: message, target_agent_ids: chat.agents.order(:id).ids, kind: "rhythm")
      occurrence = occurrences.create!(
        chat: chat, message: message, creator: creator, creator_agent: creator_agent, creator_label: creator_label,
        title: occurrence_title, rhythm_title: title, opening: opening, scheduled_for: scheduled_for,
        manual: manual, request_key: manual ? request_key : nil
      )
      update!(next_run_at: next_occurrence(after: now)) unless manual
      Result.new(status: :created, occurrence: occurrence)
    end
    result
  rescue StandardError => error
    # Rails callbacks can fail after commit. A committed occurrence is accepted,
    # not permission to create another room when the caller retries.
    raise unless occurrence&.id && RhythmOccurrence.exists?(occurrence.id)

    Rails.logger.warn "[Rhythm] #{id} occurrence accepted; after-commit step failed: #{error.class}: #{error.message}"
    Result.new(status: :created, occurrence: occurrence.reload)
  end

  def pause!(holder:, reason:)
    with_lock do
      attributes = holder_attributes(holder)
      next Result.new(status: :forbidden) unless attributes

      hold = open_holds.find_or_initialize_by(attributes)
      hold.reason = reason
      hold.save!
      Result.new(status: :held, reason: reason)
    end
  end

  def resume!(holder:)
    with_lock do
      if holder.is_a?(Agent)
        # Selection changes never erase a resident's hold. Its author can still
        # release it after being removed from the selection or guest membership.
        own_holds = open_holds.where(kind: "agent", agent_id: holder.id)
        system_holds = open_holds.where(kind: "system")
        can_release_system = manageable_by_agent?(holder) && system_holds.exists?
        next Result.new(status: :forbidden) unless own_holds.exists? || can_release_system
        if can_release_system && (reason = unavailable_reason)
          next Result.new(status: :unavailable, reason: reason)
        end

        own_holds.update_all(released_at: Time.current, updated_at: Time.current)
        system_holds.update_all(released_at: Time.current, updated_at: Time.current) if can_release_system
      elsif holder.is_a?(User) && manageable_by?(holder)
        if open_holds.where(kind: "system").exists? && (reason = unavailable_reason)
          next Result.new(status: :unavailable, reason: reason)
        end
        open_holds.where(kind: %w[human system]).update_all(released_at: Time.current, updated_at: Time.current)
      else
        next Result.new(status: :forbidden)
      end
      if held?
        Result.new(status: :held)
      else
        update!(next_run_at: next_occurrence(after: Time.current))
        Result.new(status: :active)
      end
    end
  end

  private

  def one_creator
    if creator && creator_agent
      errors.add(:creator, "must be either a human or a resident, not both")
    elsif new_record? && !creator && !creator_agent
      errors.add(:creator, "must be present")
    end
  end

  def creator_label
    creator_agent&.name || creator&.full_name.presence || creator&.email_address&.split("@")&.first
  end

  def holder_attributes(holder)
    case holder
    when User
      { kind: "human", user_id: holder.id } if manageable_by?(holder)
    when Agent
      { kind: "agent", agent_id: holder.id } if agents.exists?(holder.id) || manageable_by_agent?(holder)
    when :system
      { kind: "system" }
    end
  end

  def add_system_hold!(reason)
    hold = open_holds.find_or_initialize_by(kind: "system")
    hold.update!(reason: reason)
  end

  def hold_empty_selection
    add_system_hold!("no_selected_residents") unless agents.exists?
  end

  def unavailable_reason
    if creator_agent
      return "creator_not_member" unless account.conversation_agents.exists?(creator_agent.id)
      return "creator_unavailable" unless creator_agent.reload.eligible_for_conversation?
      return "creator_paused" if creator_agent.paused?
    else
      return "creator_not_member" unless creator&.confirmed_accounts&.exists?(account_id)
    end
    return "live_activity_disabled" unless AgentRuntimeInteraction.live_activity_enabled?
    selected = agents.reload.to_a
    return "no_selected_residents" if selected.empty?

    present_ids = account.conversation_agents.where(id: selected.map(&:id)).ids
    selected.each do |agent|
      return "resident_not_present: #{agent.name}" unless present_ids.include?(agent.id)
      return "resident_unavailable: #{agent.name}" unless agent.eligible_for_conversation?
      return "resident_paused: #{agent.name}" if agent.paused?
    end
    nil
  end

  def residents_present_in_account
    return unless account
    selected_ids = agents.map(&:id)
    present_ids = account.conversation_agents.where(id: selected_ids).ids
    errors.add(:agents, "must be residents of this account or accepted guests") unless (selected_ids - present_ids).empty?
  end

  def schedule_changed?
    new_record? || SCHEDULE_FIELDS.any? { |field| will_save_change_to_attribute?(field) }
  end

  def reset_next_run
    # Let validations report malformed input instead of failing date arithmetic.
    return unless %w[daily weekly monthly yearly].include?(cadence)
    return unless ActiveSupport::TimeZone[timezone] && time_of_day.to_s.match?(/\A(?:[01]\d|2[0-3]):[0-5]\d\z/)
    return if weekly? && !weekday.in?(0..6)
    return if (monthly? || yearly?) && !month_day.in?(1..31)
    return if yearly? && !month.in?(1..12)

    self.next_run_at = next_occurrence(after: Time.current) unless new_record? && next_run_at.present?
  end

end
