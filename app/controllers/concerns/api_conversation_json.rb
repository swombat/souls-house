# The conversation shape /api/v1 returns in lists and after a change.
module ApiConversationJson

  private

  def conversation_json(chat)
    {
      id: chat.to_param,
      title: chat.title_or_default,
      visual_tag: chat.visual_tag&.as_json,
      summary: chat.discarded? ? nil : chat.summary,
      summary_stale: chat.summary_stale?,
      model: chat.model_label,
      model_id: chat.model_id,
      web_access: chat.web_access,
      group_chat: chat.group_chat?,
      archived: chat.archived?,
      deleted: chat.discarded?,
      message_count: chat.message_count,
      updated_at: chat.updated_at.iso8601
    }.merge(conversation_room_json(chat))
  end

  # { room: { id:, name: } }, id nil for Main; nothing at all for a guest resident.
  def conversation_room_json(chat)
    return {} unless rooms_visible_in?(chat.account)

    { room: chat.room ? chat.room.as_json : { "id" => nil, "name" => chat.account.main_room_label } }
  end

end
