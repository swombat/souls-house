# The durable intent to wake the residents a human message mentioned (#94 B,
# step 4b-ii). It is written in the transaction that accepts the message, so
# an accepted send cannot lose its wake to a failed enqueue: the queue is only
# ever written after that commit, and the sweeper re-drives what it missed.
#
# Deduplication is the runtime interaction, not the queue. Reserving happens
# under this row's lock and records the interaction in the same transaction,
# so any number of MessageDispatchJob deliveries reserve at most one; after
# that, the interaction's own claim_dispatch! gates the runtime request. That
# guards one application-level dispatch per interaction. It is not an
# exactly-once transport, and an unknown runtime outcome stays unknown.
#
# Lock order: this row is always taken before any interaction or chat lock.
class MessageDispatch < ApplicationRecord

  STATUSES = %w[pending reserved cancelled expired].freeze
  EXPIRY = 10.minutes
  # Recovery looks back this far and no further, so it never wakes chains
  # that were not created by a dispatch it is responsible for.
  RECOVERY_HORIZON = 6.hours
  # A fresh row's own enqueue gets this long before the sweeper assumes it
  # was lost.
  REDRIVE_GRACE = 30.seconds

  belongs_to :message
  belongs_to :chat
  belongs_to :user
  belongs_to :runtime_interaction, class_name: "AgentRuntimeInteraction", optional: true
  has_many :runtime_interactions, class_name: "AgentRuntimeInteraction", dependent: :nullify

  validates :status, inclusion: { in: STATUSES }

  scope :recoverable, -> { where(accepted_at: RECOVERY_HORIZON.ago..) }

  # Targets are resolved once, here, and never re-read from an edited body.
  def self.accept!(message:, target_agent_ids:)
    now = Time.current
    create!(message: message, chat: message.chat, user: message.user, target_agent_ids: target_agent_ids,
            accepted_at: now, expires_at: now + EXPIRY)
  end

  def pending? = status == "pending"
  def reserved? = status == "reserved"

  # MessageDispatchJob's work. Idempotent: anything but a pending, unexpired,
  # still-valid dispatch returns without effect.
  def reserve!
    with_lock do
      next unless pending?
      next settle!("expired", "not_started_in_time") if expires_at.past?
      next settle!("cancelled", "live_activity_disabled") unless AgentRuntimeInteraction.live_activity_enabled?
      if (reason = source_invalid_reason)
        next settle!("cancelled", reason)
      end

      busy = false
      target_agent_ids.each_with_index do |agent_id, index|
        agent = chat.agents.find_by(id: agent_id) or next
        begin
          interaction = AgentRuntimeInteraction.reserve!(
            agent: agent, chat: chat, enqueue: true, message_dispatch: self, deadline: expires_at,
            response_chain_agent_ids: target_agent_ids.drop(index + 1)
          )
          update!(status: "reserved", runtime_interaction: interaction)
          break
        rescue Agent::RuntimeAvailability::Unavailable
          next
        rescue ArgumentError
          # Already responding: this send's request for them is dropped, as
          # the web has always dropped a mention of a busy resident.
          busy = true
          next
        end
      end
      settle!("cancelled", busy ? "target_busy" : "no_available_target") if pending?
    end
  end

  # Called by an interaction's claim under this row's lock: may the run this
  # dispatch caused (or continued) still start? Settles the dispatch if not.
  def deliverable!
    return false unless reserved?

    reason = source_invalid_reason
    reason ||= "live_activity_disabled" unless AgentRuntimeInteraction.live_activity_enabled?
    return true unless reason

    settle!("cancelled", reason)
    false
  end

  # An edit while pending cancels the request; after reservation it does not
  # retract it, and the resident reads the body current when it runs. The
  # caller holds this row's lock across the edit.
  def source_edited!
    settle!("cancelled", "edited") if pending?
  end

  # A discard cancels pending and reserved-but-unclaimed work, the first run
  # and any continuation. A run whose claim already won may have reached the
  # runtime; discard hides the message but cannot recall that run. The caller
  # holds this row's lock across the discard.
  def source_discarded!
    return unless pending? || reserved?

    runtime_interactions.where(dispatch_claimed_at: nil, finished_at: nil).find_each do |interaction|
      interaction.with_lock do
        interaction.finish_execution!("cancelled") if interaction.dispatch_claimed_at.nil?
      end
    end
    settle!("cancelled", "discarded")
  end

  # Re-drive whatever an enqueue may have lost: the dispatch itself while
  # pending, and, once reserved, every unclaimed interaction and every ready
  # but unadvanced continuation belonging to it. Every job here is safe to
  # deliver twice.
  def redrive!(grace: REDRIVE_GRACE)
    reload
    if pending?
      return settle_expired! if expires_at.past?
      MessageDispatchJob.perform_later(self) if accepted_at <= grace.ago
      return
    end
    return unless reserved?

    runtime_interactions.where(dispatch_claimed_at: nil, finished_at: nil, execution_state: "queued")
      .where("created_at <= ?", grace.ago).where("execution_deadline_at > ?", Time.current).find_each do |interaction|
      ManualAgentResponseJob.perform_later(chat, interaction.agent, runtime_interaction_id: interaction.id)
    end
    runtime_interactions.where(response_chain_advanced_at: nil).where.not(response_chain_agent_ids: [])
      .where("updated_at <= ?", grace.ago).find_each do |interaction|
      next unless interaction.response_chain_ready?

      AllAgentsResponseJob.perform_later(chat, interaction.response_chain_agent_ids, after_interaction_id: interaction.id)
    end
  end

  # What the author sees. A 200 retry means "accepted" and nothing more; this
  # is how they learn what became of the wake.
  def as_app_json
    {
      status: status,
      reason: reason,
      expires_at: expires_at.iso8601(6),
      settled_at: settled_at&.iso8601(6),
      runs: runtime_interactions.order(:id).map { |interaction|
        { run_id: interaction.run_id, agent_id: interaction.agent.to_param, status: interaction.execution_state }
      }
    }
  end

  private

  def settle_expired!
    with_lock { settle!("expired", "not_started_in_time") if pending? && expires_at.past? }
  end

  def settle!(status, reason)
    update!(status: status, reason: reason, settled_at: Time.current)
  end

  def source_invalid_reason
    message.reload
    return "discarded" if message.discarded?
    return "conversation_unavailable" unless chat.reload.respondable? && chat.manual_responses?
    return "author_not_member" unless user.confirmed_accounts.exists?(chat.account_id)

    nil
  end

end
