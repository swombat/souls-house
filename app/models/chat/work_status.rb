module Chat::WorkStatus

  extend ActiveSupport::Concern

  STATES = %w[working ready_for_review needs_input blocked completed idle].freeze
  WAITING_STATES = %w[needs_input blocked].freeze
  REASON_LIMIT = 1000

  class Invalid < StandardError; end
  class Conflict < StandardError; end

  included do
    validates :work_status, inclusion: { in: STATES }, allow_nil: true
    validates :work_status_reason, length: { maximum: REASON_LIMIT }
    validates :work_status_reason, presence: true, if: -> { work_status.in?(WAITING_STATES) }

    scope :work_replied, -> {
      where(work_status: WAITING_STATES).where(<<~SQL.squish)
        EXISTS (SELECT 1 FROM messages
          WHERE messages.chat_id = chats.id AND messages.discarded_at IS NULL
            AND messages.role = 'user' AND messages.user_id IS NOT NULL
            AND messages.created_at > chats.work_status_since)
      SQL
    }
  end

  class_methods do
    # One aggregate for an entire list, including mixed tracked/untracked rows.
    # Message writes touch the chat, so the existing JSON cache is invalidated.
    def preload_work_status_replies(chats)
      waiting = chats.select { |chat| chat.work_status.in?(WAITING_STATES) }
      replies = Message.kept.joins(:chat).where(chat_id: waiting.map(&:id), role: "user")
        .where.not(user_id: nil).where("messages.created_at > chats.work_status_since")
        .group(:chat_id).maximum(:created_at)
      chats.each { |chat| chat.instance_variable_set(:@work_status_reply_at, [ chat.cache_key_with_version, replies[chat.id] ]) }
      chats
    end

    def filter_work_status(scope, state:, replied:)
      scope = scope.where(work_status: nil) if state == "untracked"
      scope = scope.where(work_status: state) if STATES.include?(state)
      replied == "true" ? scope.work_replied : scope
    end
  end

  def work_status_json
    {
      state: work_status,
      reason: work_status_reason,
      since: work_status_since&.iso8601(6),
      revision: work_status_revision,
      human_replied_since: work_status_reply_at&.iso8601(6)
    }
  end

  # Reported metadata only. Completed is not acceptance or permission to archive.
  # Call inside with_work_status_authority!, which takes the chat write lock.
  def change_work_status!(state:, reason:, expected_revision:)
    unless expected_revision.is_a?(Integer) && expected_revision >= 0
      raise Invalid, "expected_revision must be a nonnegative integer"
    end
    raise Invalid, "state must be null or a supported work status" unless state.nil? || STATES.include?(state)
    unless reason.nil? || (reason.is_a?(String) && reason.length <= REASON_LIMIT && !reason.include?("\0"))
      raise Invalid, "reason must be null or text of at most #{REASON_LIMIT} characters without NUL"
    end
    raise Invalid, "reason is required for #{state}" if state.in?(WAITING_STATES) && reason.blank?
    raise Invalid, "reason must be null when tracking is stopped" if state.nil? && !reason.nil?
    raise Conflict, "Work status changed; refresh and try again" unless expected_revision == work_status_revision
    return false if state == work_status && reason == work_status_reason

    update!(work_status: state, work_status_reason: reason,
      work_status_since: state ? Time.current : nil, work_status_revision: work_status_revision + 1)
    remove_instance_variable(:@work_status_reply_at) if instance_variable_defined?(:@work_status_reply_at)
    true
  end

  # Guest membership precedes the chat lock, like guest departure. The seat is
  # rechecked after locking, so a previously fetched conversation grants nothing.
  def with_work_status_authority!(agent: nil, user: nil)
    self.class.transaction do
      destination = Account.where(id: account_id, disabled_at: nil).lock("FOR SHARE").take!
      if agent
        agent = Agent.lock("FOR SHARE").find(agent.id)
        raise ActiveRecord::RecordNotFound unless agent.eligible_for_conversation?
        if agent.account_id != account_id
          GuestMembership.where(account_id: account_id, agent_id: agent.id).lock("FOR SHARE").take!
        end
        with_lock do
          raise ActiveRecord::RecordNotFound if discarded? || account_id != destination.id
          chat_agents.where(agent_id: agent.id).take!
          yield
        end
      else
        # No site-admin or key-owner widening: current membership is required.
        Membership.confirmed.where(account_id: account_id, user_id: user&.id).lock("FOR SHARE").take!
        with_lock do
          raise ActiveRecord::RecordNotFound if discarded? || account_id != destination.id
          yield
        end
      end
    end
  end

  private

  def work_status_reply_at
    return nil unless work_status.in?(WAITING_STATES) && work_status_since
    if instance_variable_defined?(:@work_status_reply_at) && @work_status_reply_at.first == cache_key_with_version
      return @work_status_reply_at.last
    end

    messages.kept.where(role: "user").where.not(user_id: nil)
      .where("created_at > ?", work_status_since).maximum(:created_at)
  end

end
