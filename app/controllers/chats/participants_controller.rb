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

    unless add_participant(agent)
      redirect_back_or_to chat_view_path(@chat),
        alert: "#{agent.name} is already in this conversation"
      return
    end

    redirect_to chat_view_path(@chat)
  end

  # PATCH /accounts/:account_id/chats/:chat_id/participant
  # The Manage residents dialog sends the whole set it wants seated. Seats are
  # added and removed one at a time with the same rules as create/destroy;
  # one that cannot change (still responding, not yours to remove) is named
  # back and the others still go through.
  def update
    unless @chat.group_chat?
      redirect_back_or_to chat_view_path(@chat), alert: "Can only add residents to group chats"
      return
    end

    return head :bad_request unless params.key?(:agent_ids)

    wanted = Array(params[:agent_ids]).grep(String).compact_blank.uniq
    seated = @chat.agents.to_a
    seated_ids = seated.map(&:to_param)
    eligible = current_account.conversation_agents.eligible_for_conversation
    refused = []

    (wanted - seated_ids).each do |agent_param|
      add_participant(eligible.find(agent_param))
    rescue ActiveRecord::RecordNotFound
      refused << "One resident is no longer available to add"
    end

    seated.reject { |agent| wanted.include?(agent.to_param) }.each do |agent|
      @chat.remove_participant!(agent, by: Current.user) do
        audit("remove_agent_from_chat", @chat, agent_id: agent.id)
      end
    rescue Chat::AlreadyResponding => error
      refused << error.message
    rescue Account::NotAuthorized
      refused << "You can't remove #{agent.name} from this conversation"
    end

    if refused.any?
      redirect_to chat_view_path(@chat), alert: refused.join(". ")
    else
      redirect_to chat_view_path(@chat)
    end
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

  private

  def add_participant(agent)
    added = @chat.with_lock do
      next false if @chat.agents.exists?(agent.id)

      @chat.agents << agent
      @chat.messages.create!(
        role: "user",
        content: "[System Notice] #{agent.name} has joined the conversation."
      )
      true
    end
    audit("add_agent_to_chat", @chat, agent_id: agent.id) if added
    added
  end

end
