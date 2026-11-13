# A conversation run that failed because the model provider's edge or
# servers failed the request (FailureReport::PROVIDER_EDGE_CATEGORIES: a
# Cloudflare challenge, a 5xx, an overload) is not a loop of the resident's
# own. On 13 Nov 2026 a five-minute Cloudflare challenge on Anthropic's edge
# ate eight turns, the follow-through nudge with them, and left a room
# orphaned until a person noticed (eOyrdJ).
#
# Two wakes, both of the room the failure happened in, both continuing that
# failed run (provider_retry_of, unique: one wake per failed run, however
# many jobs or completions ask):
#
# - backoff: BACKOFF after the failure, while the chain is short;
# - recovery: when a later run of the same resident completes anywhere,
#   showing the provider answers again, a room whose latest run of the
#   resident is still such a failure, within RECOVERY_WINDOW, is woken once.
#
# Neither wakes a room where anything came after the failure (a later run
# of the resident there, which also covers a person's own wake), nor a
# paused or unseated resident, nor a closed room.
#
# The bound, as one number: MAX_WAKES. A chain is a failed run and the wakes
# that continue it (provider_retry_of); it gets at most MAX_WAKES wakes, the
# first BACKOFF.size of them by backoff and the rest only by recovery, so at
# most MAX_WAKES + 1 runs in all. And a resident gets at most MAX_WAKES of
# these wakes in one room within RECOVERY_WINDOW, whatever the chains (a
# failure that arrives through a nudge or a person's wake starts a new one).
# Recovery coalesces: it picks up the room's newest failed run, and the
# unique index makes concurrent asks one wake.
class ProviderEdgeRetry

  BACKOFF = [ 2.minutes, 5.minutes ].freeze
  MAX_WAKES = 3
  RECOVERY_WINDOW = 6.hours

  attr_reader :failed

  def initialize(failed)
    @failed = failed
  end

  def self.edge_failure?(run)
    run.trigger_kind == "conversation" && run.chat_id.present? &&
      run.failure_category.in?(AgentRuntimeInteraction::FailureReport::PROVIDER_EDGE_CATEGORIES)
  end

  # Queued when a conversation run finishes failed on the provider's edge.
  def self.schedule(run)
    return unless edge_failure?(run)

    wait = BACKOFF[new(run).depth]
    ProviderEdgeRetryJob.set(wait: wait).perform_later(run.id, "backoff") if wait
  end

  # The resident's rooms whose latest run of it is a provider-edge failure
  # still waiting, recent enough to pick up again.
  def self.recover_for(agent, completed:)
    candidates = agent.agent_runtime_interactions
      .where(trigger_kind: "conversation").where.not(chat_id: nil)
      .where(execution_state: AgentRuntimeInteraction::FailureReport::FAILURE_STATES)
      .where("finished_at > ? AND finished_at <= ?", RECOVERY_WINDOW.ago, completed.finished_at)
      .where.not(id: AgentRuntimeInteraction.where.not(provider_retry_of_id: nil).select(:provider_retry_of_id))
      .order(finished_at: :desc)
    candidates.to_a.uniq(&:chat_id).each do |run|
      new(run).wake!(:recovery, recovered_at: completed.finished_at) if edge_failure?(run)
    end
  end

  # How many provider-edge wakes this failed run already continues.
  def depth
    count = 0
    run = failed
    while (run = run.provider_retry_of) && count < MAX_WAKES
      count += 1
    end
    count
  end

  # :woken, or why not. Every mutable check runs under the room's lock and
  # then the resident's, in the transaction that reserves the wake and posts
  # its notice (lock order as in reserve!: chat, then agent), so a run that
  # arrives between a check and the reservation can't be overtaken.
  def wake!(reason, recovered_at: nil)
    return :not_edge unless self.class.edge_failure?(failed)

    chat = failed.chat
    chat.transaction do
      chat.lock!
      agent = failed.agent.lock!
      refusal = refusal_reason(agent)
      next refusal if refusal

      AgentRuntimeInteraction.reserve!(agent: agent, chat: chat, enqueue: true, provider_retry_of: failed,
        requested_at: requested_at)
      chat.messages.create!(role: "user", content: notice(reason, recovered_at))
      :woken
    end
  rescue ActiveRecord::RecordNotUnique
    :already_woken
  rescue Agent::RuntimeAvailability::Unavailable, Chat::AlreadyResponding, Chat::ParticipantChanged, ArgumentError => error
    Rails.logger.info("Provider-edge wake for interaction #{failed.id} not sent: #{error.class}")
    :unavailable
  end

  # Why this failed run may not (or may no longer) be picked up, or nil.
  # Read at reservation, under the locks, and again when the woken run is
  # claimed for dispatch (claim_provider_retry!), excluding that run itself.
  def refusal_reason(agent, woken: nil)
    chat = failed.chat
    return :unavailable if agent.paused? || !agent.active? || !agent.eligible_for_conversation?
    return :unavailable unless chat.respondable? && chat.manual_responses? && !chat.account.disabled?
    # The same seat boundary reserve! enforces: a removal, or a removal and
    # re-seating, after the failed request ends this retry.
    return :unseated unless chat.agent_seated_for_request?(agent.id, requested_at)
    return :chain_full if depth >= MAX_WAKES
    return :superseded if superseded?(except: woken)
    return :room_full if room_wakes(except: woken) >= MAX_WAKES

    nil
  end

  # What the woken run is told. Grants nothing; points at the failure.
  def prompt_text
    <<~TEXT.strip
      PROVIDER RETRY (platform, not a person). Your run in conversation #{failed.chat.to_param} that ended at #{failed.finished_at.iso8601} failed before it could finish: #{cause}. That was the model provider, not you, so the house is waking you once to pick it up.

      First read the room: what you were answering, and anything that has happened since. If the next move is yours, take it now within the authorisation you already had, or say plainly what is blocking it. If there is nothing for you to do, say nothing. This wake grants no new permissions.
    TEXT
  end

  private

  def requested_at
    failed.response_requested_at || failed.created_at
  end

  def cause
    RunFailureNotice::NO_REPLY_CAUSES.fetch(failed.failure_category)
  end

  def notice(reason, recovered_at)
    name = failed.agent.name
    ended = failed.finished_at.in_time_zone(zone).strftime("%H:%M %Z")
    # The run id makes each failed run's notice its own, even within a minute.
    lead = "[System Notice] #{name}'s run here that ended at #{ended} (run #{failed.run_id.to_s.first(8)}) failed: #{cause}."
    if reason == :recovery
      at = recovered_at&.in_time_zone(zone)&.strftime("%H:%M %Z")
      "#{lead} A later run of #{name}'s completed#{" at #{at}" if at}, so waking #{name} once to pick this up."
    else
      "#{lead} Waking #{name} once more to pick it up."
    end
  end

  def zone
    ActiveSupport::TimeZone[failed.chat.account.owner&.timezone.to_s] || ActiveSupport::TimeZone["UTC"]
  end

  def room_wakes(except: nil)
    failed.chat.agent_runtime_interactions.where(agent_id: failed.agent_id).where.not(provider_retry_of_id: nil)
      .where("created_at > ?", RECOVERY_WINDOW.ago).where.not(id: except&.id).count
  end

  # Something came after the failure: a later run of this resident in the
  # room (a person's wake, a nudge, a handoff), or one already queued.
  def superseded?(except: nil)
    failed.chat.agent_runtime_interactions.where(agent_id: failed.agent_id)
      .where("created_at > ?", failed.created_at).where.not(id: [ failed.id, except&.id ].compact).exists?
  end

end
