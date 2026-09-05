class Chats::ParticipantsController < ApplicationController

  include ChatScoped

  # POST /accounts/:account_id/chats/:chat_id/participant
  def create
    unless @chat.group_chat?
      redirect_back_or_to account_chat_path(current_account, @chat),
        alert: "Can only add agents to group chats"
      return
    end

    agent = current_account.agents.eligible_for_conversation.find(params[:agent_id])

    if @chat.agents.include?(agent)
      redirect_back_or_to account_chat_path(current_account, @chat),
        alert: "#{agent.name} is already in this conversation"
      return
    end

    @chat.transaction do
      @chat.agents << agent
      @chat.messages.create!(
        role: "user",
        content: "[System Notice] #{agent.name} has joined the conversation."
      )
    end

    audit("add_agent_to_chat", @chat, agent_id: agent.id)
    redirect_to account_chat_path(current_account, @chat)
  end

end
