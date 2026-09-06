class ManualAgentResponseJob < ApplicationJob

  def perform(chat, agent, initiation_reason: nil, runtime_interaction_id: nil)
    interaction = if runtime_interaction_id
      chat.agent_runtime_interactions.find_by!(id: runtime_interaction_id, agent: agent)
    end
    unless chat.respondable? && chat.manual_responses? && chat.agents.exists?(agent.id)
      cancel_unclaimed(interaction)
      return
    end
    agent.reload
    agent.require_conversation_runtime!
    ExternalAgentResponseRequest.new(
      agent: agent, chat: chat, requested_by: "souls.house",
      initiation_reason: initiation_reason, interaction: interaction
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
