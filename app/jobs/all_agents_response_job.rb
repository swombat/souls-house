class AllAgentsResponseJob < ApplicationJob

  def perform(chat, agent_ids, after_interaction_id: nil)
    return if agent_ids.empty? || !chat.respondable? || !chat.manual_responses?

    if after_interaction_id
      previous = chat.agent_runtime_interactions.find(after_interaction_id)
      previous.with_lock do
        return unless previous.response_chain_ready? && previous.response_chain_agent_ids == agent_ids
        # Reserve the next run and consume the continuation in the same primary
        # DB transaction. Duplicate queue deliveries cannot start another run.
        dispatch_next(chat, agent_ids)
        previous.update!(response_chain_advanced_at: Time.current)
      end
    else
      dispatch_next(chat, agent_ids)
    end
  end

  private

  def dispatch_next(chat, agent_ids)
    agent = chat.agents.find_by(id: agent_ids.first)
    if agent && AgentRuntimeInteraction.live_activity_enabled?
      begin
        AgentRuntimeInteraction.reserve!(agent: agent, chat: chat, enqueue: true,
          response_chain_agent_ids: agent_ids.drop(1))
        return
      rescue Agent::RuntimeAvailability::Unavailable
        # Removed/disabled residents do not stall a requested round.
        agent = nil
      rescue ArgumentError
        ActionCable.server.broadcast("Chat:#{chat.to_param}", {
          action: "error", message: "Agent chain stopped: resident is already responding or the conversation is unavailable."
        })
        return
      end
    end
    result = ManualAgentResponseJob.perform_now(chat, agent) if agent
    if result.is_a?(Hash) && (result[:status] == 0 || result[:status] == 409 || result[:execution_unconfirmed])
      ActionCable.server.broadcast("Chat:#{chat.to_param}", {
        action: "error",
        message: "Agent chain stopped: execution could not be confirmed. Remaining residents were not started."
      })
      return
    end
    remaining = agent_ids.drop(1)
    self.class.perform_later(chat, remaining) if remaining.any?
  end

end
