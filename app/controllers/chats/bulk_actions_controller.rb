# The sidebar's Actions menu: mark many conversations read, or tag them, in
# one request (ConversationBulk). JSON in and out; the list then refreshes
# from the account broadcast like any single change.
class Chats::BulkActionsController < ApplicationController

  require_feature_enabled :chats

  rescue_from ConversationBulk::InvalidIds do |error|
    render json: { error: error.message }, status: :unprocessable_entity
  end

  # POST /accounts/:account_id/chats/bulk/mark_read { conversation_ids: [...] }
  def mark_read
    # Like a single dismissal: reply attention needs real membership, not
    # site-admin browsing.
    account = Current.user.confirmed_accounts.find(params[:account_id])
    ids = ConversationBulk.decode_ids(conversation_ids_param)
    acted = ConversationBulk.mark_read!(chats: account.chats.kept.where(id: ids), user: Current.user)
    audit("bulk_dismiss_reply_expectations", nil, conversation_ids: acted)
    render json: { conversation_ids: acted }
  end

  # PATCH /accounts/:account_id/chats/bulk/visual_tag { conversation_ids: [...], visual_tag_id: "abc" | null }
  def visual_tag
    unless params.key?(:visual_tag_id)
      return render json: { error: "visual_tag_id must be provided (or null to clear)" }, status: :unprocessable_entity
    end

    ids = ConversationBulk.decode_ids(conversation_ids_param)
    tag = VisualTag.resolve_for(current_account, params[:visual_tag_id])
    changed = ConversationBulk.set_tag!(chats: current_account.chats.kept.where(id: ids), tag: tag, by: Current.user)
    audit("bulk_set_visual_tag", nil, conversation_ids: changed, visual_tag_id: tag&.to_param)
    render json: { conversation_ids: changed, visual_tag: tag&.as_json }
  rescue ActiveRecord::InvalidForeignKey
    render json: { error: "This tag is no longer available. Refresh the palette and try again." }, status: :unprocessable_entity
  end

  private

  def conversation_ids_param
    raw = params[:conversation_ids]
    raw.is_a?(Array) ? raw : nil
  end

end
