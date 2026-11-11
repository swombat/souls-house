# Runs the fallback attempt of a turn the subscription refused before it
# started (#690, ResidentFallback::Hop). If the hop can't run after all (the
# switch went off, the policy no longer admits, the room changed, another
# run started), the subscription's refusal is told in the room as it was
# before the hop existed.
class ResidentFallbackHopJob < ApplicationJob

  # The refused run finishes in the transaction that opened the hop; wait
  # for it rather than meeting it as "already responding".
  WAITS = 5

  def perform(turn_id, wait: 0)
    turn = ResidentFallbackTurn.find_by(id: turn_id)
    return unless turn && turn.fallback_interaction_id.nil? && turn.chat

    primary = turn.primary_interaction
    if primary && primary.reload.finished_at.nil?
      return wait < WAITS ? self.class.set(wait: 2.seconds).perform_later(turn_id, wait: wait + 1) : tell_refusal(turn)
    end
    agent, chat = turn.agent, turn.chat
    unless Setting.instance.paid_fallback_enabled? && ResidentFallback::Decision.for(agent).ok? &&
        agent.fallback_policy.model_id == turn.fallback_model_id
      return tell_refusal(turn)
    end

    interaction = AgentRuntimeInteraction.reserve!(
      agent: agent, chat: chat, wake_source_kinds: primary&.wake_source_kinds || [],
      requested_at: primary&.response_requested_at || turn.created_at
    )
    turn.update!(fallback_interaction: interaction)
    ExternalAgentResponseRequest.new(
      agent: agent, chat: chat, requested_by: "souls.house", interaction: interaction,
      wake_source_kinds: interaction.wake_source_kinds, requested_at: interaction.response_requested_at,
      fallback_turn: turn
    ).call
  rescue Chat::AlreadyResponding, Chat::ParticipantChanged, ArgumentError, Agent::RuntimeAvailability::Unavailable
    tell_refusal(turn) if turn && turn.fallback_interaction_id.nil?
  end

  private

  def tell_refusal(turn)
    snapshot = turn.primary_interaction&.response_body.to_h["subscription_usage"]
    text = AgentSubscriptionUsage.new(snapshot).user_message
    turn.chat.messages.create!(role: "assistant", agent: turn.agent, content: "_#{text}_")
  end

end
