class Chats::AgentAssignmentsController < ApplicationController

  include ChatScoped

  # POST /accounts/:account_id/chats/:chat_id/agent_assignment
  def create
    if @chat.manual_responses?
      redirect_back_or_to chat_view_path(@chat),
        alert: "This chat is already assigned to a resident"
      return
    end

    agent = current_account.conversation_agents.eligible_for_conversation.find(params[:agent_id])
    @chat.assign_agent!(agent)

    audit("assign_agent_to_chat", @chat, agent_id: agent.id)
    redirect_to chat_view_path(@chat)
  end

end
