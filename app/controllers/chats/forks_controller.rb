class Chats::ForksController < ApplicationController

  include ChatScoped

  # POST /accounts/:account_id/chats/:chat_id/fork
  def create
    new_title = params[:title].presence || @chat.default_fork_title
    forked_chat = @chat.fork_with_title!(new_title)
    audit("fork_chat", forked_chat, source_chat_id: @chat.id)
    redirect_to account_chat_path(current_account, forked_chat)
  rescue ActiveRecord::RecordInvalid => error
    redirect_to account_chat_path(current_account, @chat), alert: error.record.errors.full_messages.to_sentence
  end

end
