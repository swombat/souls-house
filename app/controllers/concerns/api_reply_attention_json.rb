# One conversation's open reply flags for the key's person.
module ApiReplyAttentionJson

  private

  def reply_attention_json(chat, message_ids)
    {
      conversation_id: chat.to_param,
      title: chat.title_or_default,
      count: message_ids.size,
      message_ids: message_ids.map { |id| Message.encode_id(id) },
      # Dismissing through this message clears every flag in the conversation.
      through_message_id: message_ids.max && Message.encode_id(message_ids.max)
    }
  end

end
