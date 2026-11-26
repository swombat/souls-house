# A reference the visitor's home collects (JdWxAj): which conversation, which
# message, why. Never a prompt. Each belongs to one run here
# (AgentRuntimeInteraction), so the room's receipts read the same as for any
# resident: queued until claimed, delivered once the home fetches the
# transcript, not_collected if it never does.
class VisitorWake < ApplicationRecord

  STATES = %w[pending claimed collected completed expired].freeze
  OPEN_STATES = %w[pending claimed collected].freeze
  LEASE = 2.minutes
  # A wake nobody collects within this ends its run as not_collected.
  COLLECTION_WINDOW = 15.minutes
  # A collected run with no completion ends on its own after this.
  RUN_WINDOW = 30.minutes

  belongs_to :visitor_admission
  belongs_to :agent_runtime_interaction
  belongs_to :chat
  belongs_to :message, optional: true

  validates :state, inclusion: { in: STATES }

  scope :unfinished, -> { where(state: OPEN_STATES) }

  def interaction = agent_runtime_interaction

  # Leased claim: pending wakes, and claimed ones whose lease lapsed before
  # the home fetched the transcript. Lapsed wakes expire first.
  def self.claim_for!(admission, limit: 10)
    sweep!(admission)
    now = Time.current
    ids = admission.visitor_wakes
      .where(state: "pending").or(admission.visitor_wakes.where(state: "claimed").where("lease_expires_at < ?", now))
      .order(:id).limit(limit).lock("FOR UPDATE SKIP LOCKED").pluck(:id)
    where(id: ids).update_all([ "state = 'claimed', lease_expires_at = ?, claim_count = claim_count + 1, updated_at = ?", now + LEASE, now ])
    where(id: ids).order(:id).includes(:chat, :message).to_a
  end

  def self.sweep!(admission)
    admission.visitor_wakes.where(state: %w[pending claimed]).where("created_at < ?", COLLECTION_WINDOW.ago).find_each(&:expire!)
    admission.visitor_wakes.where(state: "collected").where("collected_at < ?", RUN_WINDOW.ago).find_each(&:complete!)
  end

  def self.open_for!(interaction:, admission:, chat:, reason:)
    create!(visitor_admission: admission, agent_runtime_interaction: interaction, chat: chat,
      message: chat.messages.order(:id).last, reason: reason)
  end

  def expired? = state == "expired"
  def completed? = state == "completed"
  def collected? = state.in?(%w[collected completed])

  # The home fetched the transcript for this wake: the run read up to the
  # last message it was shown, which is what delivers handoffs
  # (Chat#agent_transcript_cursor, MessageHandoff). A second fetch of the
  # same wake shows the transcript again but starts nothing.
  def collect!(last_message_id)
    with_lock do
      return false if expired? || completed?

      first = !collected?
      interaction.with_lock do
        interaction.update!(transport_status: 200, runtime_status: "ok",
          last_included_message_id: [ interaction.last_included_message_id, last_message_id ].compact.max)
      end
      update!(state: "collected", collected_at: collected_at || Time.current)
      MessageHandoff.sync!(chat: chat, agent: interaction.agent)
      first
    end
  end

  def complete!
    with_lock do
      return false unless state.in?(OPEN_STATES)

      interaction.with_lock { interaction.finish_execution!(collected? ? "completed" : "cancelled") }
      update!(state: "completed", completed_at: Time.current)
    end
    true
  end

  # Never collected: the run ends as not_collected, which the room reads.
  def expire!
    with_lock do
      return false unless state.in?(OPEN_STATES)

      interaction.with_lock do
        if collected?
          interaction.finish_execution!("completed")
        else
          interaction.update!(error_class: "VisitorWake::NotCollected",
            error_message: "not_collected: the visitor's home did not collect this wake")
          interaction.finish_execution!("timed_out")
        end
      end
      update!(state: collected? ? "completed" : "expired", completed_at: Time.current)
      MessageHandoff.sync!(chat: chat, agent: interaction.agent)
    end
    true
  end

  def as_json(*)
    {
      id: to_param,
      conversation_id: chat.to_param,
      message_id: message&.to_param,
      reason: reason,
      state: state,
      lease_expires_at: lease_expires_at&.iso8601
    }
  end

end
