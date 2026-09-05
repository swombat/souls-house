class Chats::AgentAssignmentsController < ApplicationController

  include ChatScoped

  # POST /accounts/:account_id/chats/:chat_id/agent_assignment
  def create
    if @chat.manual_responses?
      redirect_back_or_to account_chat_path(current_account, @chat),
        alert: "This chat is already assigned to an agent"
      return
    end

    agent = current_account.agents.eligible_for_conversation.find(params[:agent_id])

    previous_model = @chat.model_label || @chat.model_id || "an AI model"

    @chat.transaction do
      @chat.agents << agent
      @chat.update!(manual_responses: true)

      @chat.messages.create!(
        role: "user",
        content: "[System Notice] This conversation is now being handled by #{agent.name}. " \
                 "The previous messages were with #{previous_model}, a base AI model that had no system prompt, " \
                 "identity, or memories. You are now taking over this conversation with your " \
                 "full capabilities and personality."
      )
    end

    audit("assign_agent_to_chat", @chat, agent_id: agent.id)
    redirect_to account_chat_path(current_account, @chat)
  end

end
