# Acts on a sweep that judged a resident has a step to take (slice 3 of
# BjZQAe). Does nothing unless waking is on (Setting#stalled_sweep_wake), the
# sweep is on (Setting#stalled_sweep_minutes) and the room's account has
# opted in, all read fresh under the room lock, not when the sweep began.
#
# A chain is the stretch of a room since its last message from a person.
# Brakes, all within one chain:
# - One wake per resident. If a resident judged to have a step was already
#   woken in this chain, the chain stops: the room is told once that this
#   check won't wake anyone there again until someone posts, and from then on
#   nobody is woken in that chain, by this sweep or any later one. The notice
#   speaks for this check only; it doesn't claim other automation is quiet.
# - Sweeper wakes and resident handoffs share the account's handoff cap.
#   Wakes are counted as runs carrying a sweep since the last person's
#   message, so a reservation made a moment ago in this same sweep counts,
#   and MessageHandoff.accept! counts them too.
# - Paused, unavailable or no-longer-seated residents are never woken; the
#   agent row is locked while deciding. ManualAgentResponseJob and the claim
#   (AgentRuntimeInteraction#claim_stalled_sweep!) check again before the
#   run reaches the runtime.
# - Evidence boundary: the room's last message must still be the one judged.
#
# Targets are the agent ids the sweep scored (would_wake_agent_ids), never
# names. Every scored resident not woken is recorded in `held` with a reason.
#
# Switching waking on is not retroactive: a room state already judged (in
# shadow or otherwise) is never judged again, so only states that arise after
# waking is on can wake anyone.
class StalledThreadWake

  def self.enabled?
    Setting.instance.stalled_sweep_wake?
  end

  # Why waking may not act in this room at all now, or nil. Read fresh.
  def self.room_refusal_reason(chat)
    setting = Setting.uncached { Setting.first }
    return "wake_off" unless setting&.stalled_sweep_wake?
    return "sweep_off" unless setting.stalled_sweep_minutes.to_i.positive?
    return "account_not_opted_in" unless Account.where(id: chat.account_id, stalled_sweep_enabled: true).exists?
    return "account_disabled" if chat.account.reload.disabled?

    nil
  end

  # Why a sweeper wake of this resident may no longer go ahead, or nil.
  def self.refusal_reason(chat:, agent:)
    reason = room_refusal_reason(chat)
    return reason if reason
    return "paused" if agent.paused?
    return "not_in_room" unless chat.agents.exists?(agent.id)
    return "unavailable" unless agent.eligible_for_conversation?

    nil
  end

  # Sweeper wakes since the room's last message from a person: the runs that
  # carry a sweep, including ones reserved earlier in this transaction.
  def self.wakes_in_chain(chat)
    runs = chat.agent_runtime_interactions.where.not(stalled_thread_sweep_id: nil)
    last_human = chat.messages.where(role: "user").where.not(user_id: nil).order(:id).last
    last_human ? runs.where("agent_runtime_interactions.created_at > ?", last_human.created_at) : runs
  end

  def initialize(sweep)
    @sweep = sweep
    @chat = sweep.chat
  end

  def call
    return if @sweep.would_wake_agent_ids.empty?

    @chat.transaction do
      @chat.lock!
      @sweep.lock!
      next unless current_last_message_id == @sweep.message_id

      targets = Agent.where(id: @sweep.would_wake_agent_ids).index_by(&:id)
      agents = @sweep.would_wake_agent_ids.filter_map { |id| targets[id] }

      # The feature and account gates come before anything with a side
      # effect, the stop notice included.
      if (reason = self.class.room_refusal_reason(@chat))
        agents.each { |agent| hold(agent, reason) }
      elsif chain_stopped?
        agents.each { |agent| hold(agent, "chain_stopped") }
      elsif (repeat = agents.find { |agent| woken_in_chain?(agent) })
        stop!(repeat)
        agents.each { |agent| hold(agent, agent == repeat ? "already_woken_in_chain" : "chain_stopped") }
      else
        agents.each { |agent| consider(agent) }
      end
      @sweep.save!
    end
  end

  def nudge_notice(agent)
    "[System Notice] Stalled-thread check: this room has been quiet for #{@sweep.quiet_minutes} minutes, and it looks " \
      "like #{agent.name} has a step to take. Waking #{agent.name} once to pick it up or say what's blocking."
  end

  def stopped_notice(agent)
    "[System Notice] Stalled-thread check: #{agent.name} was already woken once here since the last message from a " \
      "person, and the room still looks stuck. This check won't wake anyone here again until someone posts."
  end

  private

  def consider(agent)
    agent.lock!
    reason = self.class.refusal_reason(chat: @chat, agent: agent)
    return hold(agent, reason) if reason
    return hold(agent, "loop_cap") if loop_cap_reached?

    # Reserve first: if the resident can't be woken, no notice claims it was.
    AgentRuntimeInteraction.reserve!(agent: agent, chat: @chat, enqueue: true, stalled_thread_sweep: @sweep)
    @chat.messages.create!(role: "user", content: nudge_notice(agent))
    @sweep.woken_agent_ids = (@sweep.woken_agent_ids + [ agent.id ]).uniq
  rescue Agent::RuntimeAvailability::Unavailable, Chat::AlreadyResponding, ArgumentError => error
    hold(agent, error.class.name.demodulize.underscore)
  end

  def hold(agent, reason)
    @sweep.held = @sweep.held + [ { "agent_id" => agent.id, "name" => agent.name, "reason" => reason } ]
  end

  def stop!(agent)
    return if @sweep.stopped

    @chat.messages.create!(role: "user", content: stopped_notice(agent))
    @sweep.stopped = true
  end

  def chain_sweeps
    StalledThreadSweep.where(chat: @chat, human_message_id: @sweep.human_message_id)
  end

  def chain_stopped?
    @sweep.stopped || chain_sweeps.where(stopped: true).exists?
  end

  def woken_in_chain?(agent)
    self.class.wakes_in_chain(@chat).where(agent: agent).exists?
  end

  def loop_cap_reached?
    cap = @chat.account.resident_handoff_cap
    return true if cap.zero?

    MessageHandoff.counted_since_last_human_message(@chat) + self.class.wakes_in_chain(@chat).count >= cap
  end

  def current_last_message_id
    StalledThreadSnapshot.last_messages([ @chat.id ])[@chat.id]&.id
  end

end
