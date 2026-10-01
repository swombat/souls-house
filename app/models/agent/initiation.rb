module Agent::Initiation

  extend ActiveSupport::Concern

  INITIATION_CAP = 2

  def at_initiation_cap?
    pending_initiated_conversations.count >= INITIATION_CAP
  end

  def pending_initiated_conversations
    chats.kept.awaiting_human_response.where(initiated_by_agent: self)
  end

  def continuable_conversations
    chats.active.kept
         .where(manual_responses: true)
         .where.not(id: chats_where_i_spoke_last)
         .where.not(id: chats_closed_for_initiation)
         .order(updated_at: :desc)
         .limit(10)
  end

  def last_initiation_at
    chats.initiated.where(initiated_by_agent: self).maximum(:created_at)
  end

  private

  def chats_closed_for_initiation
    ChatAgent.where(agent_id: id).closed_for_initiation.select(:chat_id)
  end

  def chats_where_i_spoke_last
    Chat.where(id: chats.active.kept.where(manual_responses: true))
        .joins(:messages)
        .where("messages.id = (SELECT MAX(m.id) FROM messages m WHERE m.chat_id = chats.id)")
        .where(messages: { agent_id: id })
        .pluck(:id)
  end

end
