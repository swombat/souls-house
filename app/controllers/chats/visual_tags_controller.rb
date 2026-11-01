class Chats::VisualTagsController < ApplicationController

  def update
    chat = current_account.chats.kept.find(params[:chat_id])
    unless params.key?(:visual_tag_id)
      redirect_back_or_to chat_view_path(chat),
        inertia: { errors: { visual_tag_id: "must be provided (or null to clear)" } }
      return
    end

    tag = VisualTag.resolve_for(current_account, params[:visual_tag_id])
    # The lock reloads the row, so the "was" in the line is the tag this
    # write replaced, not whatever an overlapping request saw first.
    chat.with_lock do
      previous = chat.visual_tag
      chat.update!(visual_tag: tag)
      ConversationTagEvent.changed!(chat: chat, from: previous, to: tag, by: Current.user)
    end
    redirect_back_or_to chat_view_path(chat)
  rescue ActiveRecord::InvalidForeignKey
    redirect_back_or_to chat_view_path(chat),
      inertia: { errors: { visual_tag_id: "This tag is no longer available. Refresh the palette and try again." } }
  rescue ActiveRecord::RecordInvalid => error
    redirect_back_or_to chat_view_path(chat),
      inertia: { errors: error.record.errors.to_hash }
  end

end
