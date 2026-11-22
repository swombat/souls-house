class Chats::PrivaciesController < ApplicationController

  include ChatScoped

  # POST /accounts/:account_id/chats/:chat_id/privacy
  # Someone who has written in it, or an admin, can close it to the people in it now.
  def create
    if @chat.make_private!(by: Current.user)
      audit("make_chat_private", @chat)
      # An admin who hadn't written can no longer see it, so don't send them back to it.
      if @chat.visible_to?(Current.user)
        redirect_back_or_to chat_view_path(@chat), notice: "This conversation is now private"
      else
        redirect_to account_chats_path(@chat.account), notice: "That conversation is now private, and you are not in it"
      end
    else
      redirect_back_or_to chat_view_path(@chat)
    end
  rescue Chat::PublishedStones, Chat::NotAWriter => error
    redirect_back_or_to chat_view_path(@chat), alert: error.message
  end

end
