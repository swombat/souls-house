# Handing a bare-model conversation to a resident (chats/agent_assignment and
# the API's agent_assignment). One path, so both say the same thing to the room.
module Chat::AgentAssignable

  extend ActiveSupport::Concern

  class AlreadyAssigned < StandardError; end

  def assign_agent!(agent)
    raise AlreadyAssigned, "This chat is already assigned to a resident" if manual_responses?

    previous_model = model_label || model_id || "an AI model"

    transaction do
      agents << agent
      update!(manual_responses: true)

      messages.create!(
        role: "user",
        content: "[System Notice] This conversation is now being handled by #{agent.name}. " \
                 "The previous messages were with #{previous_model}, a base AI model that had no system prompt, " \
                 "identity, or memories. You are now taking over this conversation with your " \
                 "full capabilities and personality."
      )
    end
  end

end
