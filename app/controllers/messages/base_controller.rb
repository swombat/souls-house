class Messages::BaseController < ApplicationController

  require_feature_enabled :chats

  before_action :set_message_and_chat

  private

  # These routes carry no account in the URL, so the chat is found in any
  # account the person is a confirmed member of (as MessagesController does),
  # not only their default one: Listen and voice mode in a second account
  # used to answer 404.
  def set_message_and_chat
    @message = Message.kept.find(params[:message_id])
    @chat = if Current.user.site_admin
      Chat.kept.find(@message.chat_id)
    else
      Chat.kept.where(id: @message.chat_id, account_id: Current.user.confirmed_account_ids).first!
    end
  end

end
