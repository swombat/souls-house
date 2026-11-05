class Chats::ParticipantsController < ApplicationController

  include ChatScoped

  # POST /accounts/:account_id/chats/:chat_id/participant
  def create
    unless @chat.group_chat?
      redirect_back_or_to chat_view_path(@chat),
        alert: "Can only add residents to group chats"
      return
    end

    agent = current_account.conversation_agents.eligible_for_conversation.find(params[:agent_id])

    @chat.with_lock do
      if @chat.agents.exists?(agent.id)
        redirect_back_or_to chat_view_path(@chat),
          alert: "#{agent.name} is already in this conversation"
        return
      end

      @chat.agents << agent
      @chat.messages.create!(
        role: "user",
        content: "[System Notice] #{agent.name} has joined the conversation."
      )
    end

    audit("add_agent_to_chat", @chat, agent_id: agent.id)
    redirect_to chat_view_path(@chat)
  end

  def destroy
    return head :bad_request unless params[:agent_id].is_a?(String) && params[:agent_id].present?

    agent = @chat.agents.find(params[:agent_id])
    @chat.remove_participant!(agent, by: Current.user) do
      audit("remove_agent_from_chat", @chat, agent_id: agent.id)
    end
    redirect_to chat_view_path(@chat)
  rescue Chat::AlreadyResponding => error
    redirect_to chat_view_path(@chat), alert: error.message
  rescue Account::NotAuthorized
    head :forbidden
  end

end
