# The conversation shape /api/v1 returns in lists and after a change.
module ApiConversationJson

  private

  def conversation_json(chat)
    {
      id: chat.to_param,
      title: chat.title_or_default,
      visual_tag: chat.visual_tag&.as_json,
      summary: chat.summary,
      summary_stale: chat.summary_stale?,
      model: chat.model_label,
      model_id: chat.model_id,
      web_access: chat.web_access,
      group_chat: chat.group_chat?,
      archived: chat.archived?,
      deleted: chat.discarded?,
      message_count: chat.message_count,
      updated_at: chat.updated_at.iso8601
    }
  end

end
