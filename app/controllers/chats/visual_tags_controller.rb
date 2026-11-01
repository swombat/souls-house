class Chats::VisualTagsController < ApplicationController

  # The picker saves with a JSON request and shows the new tag at once; the
  # sidebar refreshes in the background from the chat's account broadcast. So
  # JSON gets 204, not a redirect that would re-render the whole page.
  def update
    chat = current_account.chats.kept.find(params[:chat_id])
    unless params.key?(:visual_tag_id)
      return respond_with_errors(chat, visual_tag_id: "must be provided (or null to clear)")
    end

    tag = VisualTag.resolve_for(current_account, params[:visual_tag_id])
    # The lock reloads the row, so the "was" in the line is the tag this
    # write replaced, not whatever an overlapping request saw first.
    chat.with_lock do
      previous = chat.visual_tag
      chat.update!(visual_tag: tag)
      ConversationTagEvent.changed!(chat: chat, from: previous, to: tag, by: Current.user)
    end
    respond_to do |format|
      format.json { head :no_content }
      format.any { redirect_back_or_to chat_view_path(chat) }
    end
  rescue ActiveRecord::InvalidForeignKey
    respond_with_errors(chat, visual_tag_id: "This tag is no longer available. Refresh the palette and try again.")
  rescue ActiveRecord::RecordInvalid => error
    respond_with_errors(chat, error.record.errors.to_hash)
  end

  private

  def respond_with_errors(chat, errors)
    respond_to do |format|
      format.json { render json: { errors: errors }, status: :unprocessable_entity }
      format.any { redirect_back_or_to chat_view_path(chat), inertia: { errors: errors } }
    end
  end

end
