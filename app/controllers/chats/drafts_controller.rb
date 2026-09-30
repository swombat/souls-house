class Chats::DraftsController < ApplicationController

  require_feature_enabled :chats
  include DraftAuthorBinding
  before_action :require_matching_draft_author
  include ConversationDraftActions

  private

  def conversation_draft
    @conversation_draft ||= begin
      # No site-admin widening for private writing.
      account = Current.user.confirmed_accounts.find(params[:account_id])
      chat = account.chats.find(params[:chat_id])
      ConversationDraft.for(chat: chat, user: Current.user)
    end
  end

end
