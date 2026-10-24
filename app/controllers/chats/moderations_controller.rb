class Chats::ModerationsController < ApplicationController

  include ChatScoped

  before_action :require_site_admin

  # POST /accounts/:account_id/chats/:chat_id/moderation
  def create
    count = @chat.queue_moderation_for_all_messages
    audit("moderate_all_messages", @chat, count: count)

    respond_to do |format|
      format.html { redirect_back_or_to chat_view_path(@chat), notice: "Queued moderation for #{count} messages" }
      format.json { render json: { queued: count } }
    end
  end

  private

  def require_site_admin
    unless Current.user&.site_admin
      redirect_back_or_to account_chats_path(current_account), alert: "You don't have permission to perform this action"
    end
  end

end
