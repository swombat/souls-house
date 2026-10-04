class Chats::VisualTagsController < ApplicationController

  def update
    chat = current_account.chats.kept.find(params[:chat_id])
    unless params.key?(:visual_tag_id)
      redirect_back_or_to account_chat_path(current_account, chat),
        inertia: { errors: { visual_tag_id: "must be provided (or null to clear)" } }
      return
    end

    chat.update!(visual_tag: VisualTag.resolve_for(current_account, params[:visual_tag_id]))
    redirect_back_or_to account_chat_path(current_account, chat)
  rescue ActiveRecord::InvalidForeignKey
    redirect_back_or_to account_chat_path(current_account, chat),
      inertia: { errors: { visual_tag_id: "This tag is no longer available. Refresh the palette and try again." } }
  rescue ActiveRecord::RecordInvalid => error
    redirect_back_or_to account_chat_path(current_account, chat),
      inertia: { errors: error.record.errors.to_hash }
  end

end
