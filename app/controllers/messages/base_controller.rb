class Messages::BaseController < ApplicationController

  require_feature_enabled :chats

  before_action :set_message_and_chat

  private

  def set_message_and_chat
    @message = Message.kept.find(params[:message_id])
    @chat = if Current.user.site_admin
      Chat.find(@message.chat_id)
    else
      current_account.chats.find(@message.chat_id)
    end
  end

end
