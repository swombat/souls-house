# The sidebar's Actions menu: mark many conversations read, or tag them, in
# one request (ConversationBulk). JSON in and out; the list then refreshes
# from the account broadcast like any single change.
class Chats::BulkActionsController < ApplicationController

  include ChatSidebarScope

  require_feature_enabled :chats

  # The eyes the list was showing travel as {conversation => message}. They
  # are bounded by the person's open flags, not by the length of the list;
  # this is only a sanity cap on the request.
  MAX_CUTOFFS = 5_000

  rescue_from ConversationBulk::InvalidIds do |error|
    render json: { error: error.message }, status: :unprocessable_entity
  end

  # POST /accounts/:account_id/chats/bulk/mark_read
  #   { through_message_ids: { conversation_id => message_id, ... } }
  # Each conversation is dismissed through the message its eye was showing
  # (reply_attention.through_messages), like the single eye's own button, so a
  # message that arrived after the person looked keeps its eye.
  def mark_read
    # Like a single dismissal: reply attention needs real membership, not
    # site-admin browsing.
    account = Current.user.confirmed_accounts.find(params[:account_id])
    raw = params[:through_message_ids]
    cutoffs = ConversationBulk.decode_cutoffs(raw.is_a?(ActionController::Parameters) ? raw.to_unsafe_h : nil, max: MAX_CUTOFFS)
    acted = ConversationBulk.mark_read!(chats: account.chats.kept, user: Current.user, cutoffs: cutoffs)
    audit("bulk_dismiss_reply_expectations", nil, conversation_ids: acted)
    render json: { conversation_ids: acted }
  end

  # PATCH /accounts/:account_id/chats/bulk/visual_tag
  #   { visual_tag_id: "abc" | null, room: "main" | "all" | room ID, tag:, show_hidden:, show_archived: }
  # Acts on the list the sidebar shows for that room and filter, found here
  # with the list's own query (ChatSidebarScope), so no list is too long.
  def visual_tag
    unless params.key?(:visual_tag_id)
      return render json: { error: "visual_tag_id must be provided (or null to clear)" }, status: :unprocessable_entity
    end
    unless params[:room].is_a?(String)
      return render json: { error: "room must name the list being tagged (main, all or a room ID)" }, status: :unprocessable_entity
    end

    tag = VisualTag.resolve_for(current_account, params[:visual_tag_id])
    changed = ConversationBulk.set_tag!(chats: sidebar_listing(room_from_key(params[:room])), tag: tag, by: Current.user)
    audit("bulk_set_visual_tag", nil, conversation_ids: changed, visual_tag_id: tag&.to_param)
    render json: { conversation_ids: changed, visual_tag: tag&.as_json }
  rescue ActiveRecord::InvalidForeignKey
    render json: { error: "This tag is no longer available. Refresh the palette and try again." }, status: :unprocessable_entity
  end

end
