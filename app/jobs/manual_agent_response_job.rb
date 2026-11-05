class ManualAgentResponseJob < ApplicationJob

  def perform(chat, agent, initiation_reason: nil, runtime_interaction_id: nil, wake_source_kinds: [], requested_at: nil)
    interaction = if runtime_interaction_id
      chat.agent_runtime_interactions.find_by!(id: runtime_interaction_id, agent: agent)
    end
    requested_at = interaction&.response_requested_at || interaction&.created_at || requested_at || enqueued_at || Time.current
    unless chat.respondable? && chat.manual_responses? && chat.agent_seated_for_request?(agent.id, requested_at)
      cancel_unclaimed(interaction)
      return
    end
    agent.reload
    # A follow-through nudge, a stalled-thread wake, a released pending wake
    # and a commitment's wake are deferred wakes:
    # a pause after either was reserved still stops it before it reaches the
    # runtime. (The wake's claim checks this again, with its sources.)
    deferred = interaction && (interaction.follow_through_of_id || interaction.stalled_thread_sweep_id ||
      interaction.released_pending_wake || Commitment.exists?(wake_interaction_id: interaction.id))
    if deferred && agent.paused?
      cancel_unclaimed(interaction)
      return
    end
    # A stalled-thread wake also stops if waking, the sweep or the account's
    # opt-in was switched off since it was reserved (checked again at claim).
    if interaction&.stalled_thread_sweep_id && StalledThreadWake.refusal_reason(chat: chat, agent: agent)
      cancel_unclaimed(interaction)
      return
    end
    agent.require_conversation_runtime!
    ExternalAgentResponseRequest.new(
      agent: agent, chat: chat, requested_by: "souls.house",
      initiation_reason: initiation_reason, interaction: interaction, wake_source_kinds: wake_source_kinds,
      requested_at: requested_at
    ).call
  rescue Agent::RuntimeAvailability::Unavailable => error
    cancel_unclaimed(interaction)
    ActionCable.server.broadcast("Chat:#{chat.to_param}", {
      action: "agent_skipped", agent_id: agent.to_param,
      message: "#{agent.name} is unavailable", reason: error.code
    })
  end

  private

  def cancel_unclaimed(interaction)
    return unless interaction

    interaction.with_lock do
      interaction.finish_execution!("cancelled") if interaction.dispatch_claimed_at.nil?
    end
  end

end
