class Chats::DiscardsController < ApplicationController

  include ChatScoped

  before_action :require_admin

  # POST /accounts/:account_id/chats/:chat_id/discard
  def create
    @chat.discard!
    audit("discard_chat", @chat)
    redirect_to account_chats_path(current_account), notice: "Chat deleted"
  end

  # DELETE /accounts/:account_id/chats/:chat_id/discard
  def destroy
    @chat.undiscard!
    audit("restore_chat", @chat)
    redirect_back_or_to account_chats_path(current_account), notice: "Chat restored"
  end

  private

  # Only the discard/restore operation reaches discarded parents. Ordinary
  # conversation controllers must never expose their retained children.
  def set_chat
    @chat = current_account.chats.with_discarded.find(params[:chat_id])
  end

  def require_admin
    unless current_account.manageable_by?(Current.user)
      redirect_back_or_to account_chats_path(current_account), alert: "You don't have permission to perform this action"
    end
  end

end
