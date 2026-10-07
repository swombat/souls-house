# The durable intent to wake the residents a human message mentioned (#94 B,
# step 4b-ii). It is written in the transaction that accepts the message, so
# an accepted send's intent is never lost: the queue is only ever written after
# that commit. A wake whose enqueue is lost is not recovered; the dispatch is
# recorded as expired and the person asks again (consultation BjAPDe).
#
# Deduplication is the runtime interaction, not the queue. Reserving happens
# under this row's lock and records the interaction in the same transaction,
# so any number of MessageDispatchJob deliveries reserve at most one; after
# that, the interaction's own claim_dispatch! gates the runtime request. That
# guards one application-level dispatch per interaction. It is not an
# exactly-once transport, and an unknown runtime outcome stays unknown.
#
# A native explicit invoke is the same thing with no source message (kind
# "invoke", keyed by the app's client_invocation_id): reserved inline when it
# is accepted, then claimed, continued and swept exactly like a mention wake.
#
# The automatic wake of a room's sole resident (kind "automatic") is a
# mention's lifecycle without the mention: written by Message when a human
# message is accepted, from any entry point (web, app, API, opening message),
# and reserved inline after commit so the queued activity is visible before
# the send returns. It is never presented as an explicit mention.
#
# Lock order: this row is always taken before any interaction or chat lock.
class MessageDispatch < ApplicationRecord

  # Raised to roll back a new invocation that could not reserve anything.
  class InvocationRefused < StandardError; end

  STATUSES = %w[pending reserved cancelled expired].freeze
  KINDS = %w[mention automatic rhythm invoke].freeze
  EXPIRY = 10.minutes
  # The longest a dispatch's chain may keep starting links (each link starts
  # from the previous one's normal hand-on, never from recovery), and the most
  # a turn may wait queued for capacity. Past it nothing new starts, and the
  # sweeper records what became of the dispatch (close_recovery!).
  RECOVERY_HORIZON = 6.hours

  belongs_to :message, optional: true
  belongs_to :chat
  belongs_to :user, optional: true
  belongs_to :runtime_interaction, class_name: "AgentRuntimeInteraction", optional: true
  has_many :runtime_interactions, class_name: "AgentRuntimeInteraction", dependent: :nullify

  validates :status, inclusion: { in: STATUSES }
  validates :kind, inclusion: { in: KINDS }
  validates :user, presence: true, unless: :rhythm?
  # The database's check constraint enforces the same variants; this is the
  # readable failure.
  validates :message, presence: true, if: :from_message?
  validates :message, absence: true, if: :invoke?
  validates :client_invocation_id, :request_digest, presence: true, if: :invoke?
  validates :client_invocation_id, :request_digest, absence: true, if: :from_message?

  # Reserved and still under recovery: a settled_at on a reserved row means
  # the sweeper has closed its recovery window.
  scope :recovery_open, -> { where(status: "reserved", settled_at: nil) }

  # Targets are resolved once, here, and never re-read from an edited body.
  def self.accept!(message:, target_agent_ids:, kind: "mention")
    now = Time.current
    create!(kind: kind, message: message, chat: message.chat, user: message.user, target_agent_ids: target_agent_ids,
            accepted_at: now, expires_at: now + EXPIRY)
  end

  # A native invoke, accepted and reserved in one primary transaction under
  # the chat lock, so the targets it captures and the busy check it makes are
  # the ones its reservation sees. Unlike a mention, busy is a refusal, not a
  # skip: a resident already responding raises Chat::AlreadyResponding, and
  # nothing is written. The caller has checked everything a new request needs
  # except busy; the runtime check repeats inside reserve!.
  #
  # agent is one resident, or nil for everyone in the conversation, in id
  # order at this moment. request_digest records what was asked ("all", not
  # who that resolved to), so a retry after the residents change still
  # matches and is never retargeted.
  #
  # The run's enqueue happens after the commit and can raise there. Whether
  # the invocation was accepted is whether its row exists, not whether we
  # raised; an unclaimed run is not re-driven, it lapses at its deadline.
  def self.invoke!(chat:, user:, client_invocation_id:, agent:)
    dispatch = nil
    transaction do
      chat.lock!
      targets = agent ? [ agent.id ] : chat.agents.order(:id).ids
      if agent.nil?
        busy = chat.agents.where(id: targets).order(:id).find { |a| a.eligible_for_conversation? && chat.agent_response_active?(a) }
        raise Chat::AlreadyResponding, "#{busy.name} is already responding" if busy
      end

      now = Time.current
      dispatch = create!(kind: "invoke", chat: chat, user: user, target_agent_ids: targets,
                         client_invocation_id: client_invocation_id,
                         request_digest: invocation_digest(agent&.id),
                         accepted_at: now, expires_at: now + EXPIRY)
      dispatch.reserve!
    end
    dispatch
  rescue StandardError => e
    raise unless dispatch&.id && exists?(dispatch.id)

    Rails.logger.warn "[MessageDispatch] invocation #{dispatch.id} accepted; an after-commit step failed: #{e.class}: #{e.message}"
    dispatch.reload
  end

  def self.invocation_digest(agent_id)
    "v1:" + Digest::SHA256.hexdigest({ agent: agent_id || "all" }.to_json)
  end

  def mention? = kind == "mention"
  def automatic? = kind == "automatic"
  def rhythm? = kind == "rhythm"
  # Caused by a human message, so bound to it: discard cancels, edit while
  # pending cancels, and it is swept like a mention.
  def from_message? = mention? || automatic? || rhythm?
  def invoke? = kind == "invoke"
  def pending? = status == "pending"
  def reserved? = status == "reserved"

  # Past the horizon nothing new starts from this dispatch, whichever entry
  # point (retry, linked reply, job delivery) gets there first.
  # Already-running work is not touched. On a reserved row, settled_at is the
  # sweeper's record of that closure.
  def recovery_closed? = settled_at.present? || accepted_at <= RECOVERY_HORIZON.ago

  # MessageDispatchJob's work. Idempotent: anything but a pending, unexpired,
  # still-valid dispatch returns without effect.
  #
  # An invoke only ever comes through here inline from invoke!, and never
  # settles: whatever stops it reserving raises, so the whole request rolls
  # back and nothing is recorded as accepted.
  def reserve!
    with_lock do
      next unless pending?
      reason = "not_started_in_time" if expires_at.past?
      reason ||= "live_activity_disabled" unless AgentRuntimeInteraction.live_activity_enabled?
      reason ||= source_invalid_reason
      if reason
        raise InvocationRefused, reason if invoke?
        next settle!(reason == "not_started_in_time" ? "expired" : "cancelled", reason)
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
          # One named resident who can't run is the request's answer; in a
          # round, they are skipped as the web's round skips them.
          raise if invoke? && target_agent_ids.one?
          next
        rescue ArgumentError
          # Already responding (or the conversation just became unavailable).
          # An invoke refuses; a mention drops its request for them, as the
          # web has always dropped a mention of a busy resident.
          raise if invoke?
          busy = true
          next
        end
      end
      next unless pending?
      if invoke?
        raise Agent::RuntimeAvailability::Unavailable.new("No available agents in this conversation", code: "no_available_agents")
      end
      settle!("cancelled", busy ? "target_busy" : "no_available_target")
    end
  end

  # Called by an interaction's claim under this row's lock: may the run this
  # dispatch caused (or continued) still start? Settles the dispatch if not.
  def deliverable!
    return false unless reserved?
    if recovery_closed?
      close_recovery_window!
      return false
    end

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

  # The sweeper's work, and a native send retry's: record what became of
  # lapsed work. It never starts, re-enqueues or advances anything. A wake
  # whose enqueue was lost, a run nobody claimed, a chain step that never
  # advanced: none is recovered; the person asks again (consultation BjAPDe:
  # Daniel "just click again", Chris against a retry buffer). A pending
  # dispatch past its expiry becomes expired; a reserved one has runs whose
  # deadline passed unclaimed cancelled, and past RECOVERY_HORIZON its
  # window is closed (close_recovery!).
  def settle_lapsed!
    reload
    return settle_expired! if pending? && expires_at.past?
    return unless reserved?
    return close_recovery! if recovery_closed?

    settle_expired_runs!
  end

  # Past RECOVERY_HORIZON: record the outcome. A pending dispatch is expired
  # (settle_lapsed! does that at any age); a reserved one has
  # its expired runs cancelled, and, if a continuation it owed never started,
  # becomes expired with that reason. Otherwise it stays reserved, with
  # settled_at marking recovery closed. Nothing is started or advanced here.
  def close_recovery!
    return settle_expired! if pending?

    settle_expired_runs!
    with_lock { close_recovery_window! }
  end

  # What the author sees. A 200 retry means "accepted" and nothing more; this
  # is how they learn what became of the wake.
  def as_app_json
    {
      kind: kind,
      client_invocation_id: client_invocation_id,
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

  # The caller holds this row's lock.
  def close_recovery_window!
    return unless reserved? && settled_at.nil?

    if unadvanced_owed_runs.any?
      settle!("expired", "continuation_not_started_in_time")
    else
      update!(settled_at: Time.current)
    end
  end

  def settle_expired!
    with_lock { settle!("expired", "not_started_in_time") if pending? && expires_at.past? }
  end

  # A reservation whose deadline passed unclaimed can never start; record it
  # as cancelled rather than waiting for a job delivery that may never come.
  def settle_expired_runs!
    runtime_interactions.where(dispatch_claimed_at: nil, finished_at: nil, execution_state: "queued")
      .where("execution_deadline_at <= ?", Time.current).find_each(&:reconcile_activity!)
  end

  # Continuations whose turn came but which never advanced. Closing the window
  # uses this to record what never started.
  def unadvanced_owed_runs
    runtime_interactions.where(response_chain_advanced_at: nil).where.not(response_chain_agent_ids: [])
      .select(&:response_chain_owed?)
  end

  def settle!(status, reason)
    update!(status: status, reason: reason, settled_at: Time.current)
  end

  # An invoke has no message to discard; it stands while its conversation
  # is respondable and its invoker is still a member.
  def source_invalid_reason
    if from_message?
      message.reload
      return "discarded" if message.discarded?
    end
    return "conversation_unavailable" unless chat.reload.respondable? && chat.manual_responses?
    if rhythm? && message.role == "assistant"
      author = message.agent
      return "author_not_member" unless author && chat.account.conversation_agents.exists?(author.id)
      return "author_unavailable" unless author.reload.eligible_for_conversation?
      return "author_paused" if author.paused?
    else
      return "author_not_member" unless user&.confirmed_accounts&.exists?(chat.account_id)
    end

    nil
  end

end
