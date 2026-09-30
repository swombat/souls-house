class AllAgentsResponseJob < ApplicationJob

  def perform(chat, agent_ids, after_interaction_id: nil)
    return if agent_ids.empty? || !chat.respondable? || !chat.manual_responses?

    if after_interaction_id
      previous = chat.agent_runtime_interactions.find(after_interaction_id)
      dispatch = previous.message_dispatch
      return continue_chain(chat, agent_ids, previous) unless dispatch

      # A chain a human message started carries that request with it, and is
      # serialized against its edit and discard (#94 B, step 4b-ii).
      dispatch.with_lock do
        return unless dispatch.deliverable!

        continue_chain(chat, agent_ids, previous, dispatch)
      end
    else
      dispatch_next(chat, agent_ids)
    end
  end

  private

  def continue_chain(chat, agent_ids, previous, dispatch = nil)
    previous.with_lock do
      return unless previous.response_chain_ready? && previous.response_chain_agent_ids == agent_ids
      # Reserve the next run and consume the continuation in the same primary
      # DB transaction. Duplicate queue deliveries cannot start another run.
      dispatch_next(chat, agent_ids, dispatch)
      previous.update!(response_chain_advanced_at: Time.current)
    end
  end

  def dispatch_next(chat, agent_ids, dispatch = nil)
    agent = chat.agents.find_by(id: agent_ids.first)
    if agent && (AgentRuntimeInteraction.live_activity_enabled? || ResidentTurn.enabled?)
      begin
        AgentRuntimeInteraction.reserve!(agent: agent, chat: chat, enqueue: true,
          response_chain_agent_ids: agent_ids.drop(1), message_dispatch: dispatch)
        return
      rescue Agent::RuntimeAvailability::Unavailable
        # Removed/disabled residents do not stall a requested round.
        agent = nil
      rescue ArgumentError
        ActionCable.server.broadcast("Chat:#{chat.to_param}", {
          action: "error", message: "Resident chain stopped: resident is already responding or the conversation is unavailable."
        })
        return
      end
    end
    # A dispatch's chain never leaves the reserved path: skip to the next
    # resident here, keeping the link, rather than as an unlinked new job.
    return dispatch_next(chat, agent_ids.drop(1), dispatch) if dispatch && agent_ids.many?
    return if dispatch

    result = ManualAgentResponseJob.perform_now(chat, agent) if agent
    if result.is_a?(Hash) && (result[:status] == 0 || result[:status] == 409 || result[:execution_unconfirmed])
      ActionCable.server.broadcast("Chat:#{chat.to_param}", {
        action: "error",
        message: "Resident chain stopped: execution could not be confirmed. Remaining residents were not started."
      })
      return
    end
    remaining = agent_ids.drop(1)
    self.class.perform_later(chat, remaining) if remaining.any?
  end

end
