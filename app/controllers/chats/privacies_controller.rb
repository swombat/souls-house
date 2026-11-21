class Chats::PrivaciesController < ApplicationController

  include ChatScoped

  # POST /accounts/:account_id/chats/:chat_id/privacy
  # Anyone who can see the conversation can close it to the people in it now.
  def create
    if @chat.make_private!(by: Current.user)
      audit("make_chat_private", @chat)
      redirect_back_or_to chat_view_path(@chat), notice: "This conversation is now private"
    else
      redirect_back_or_to chat_view_path(@chat)
    end
  end

end
