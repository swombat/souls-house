class Chats::ReplyDismissalsController < ApplicationController

  def create
    # Unlike site-admin browsing, reply attention requires actual membership.
    account = Current.user.confirmed_accounts.find(params[:account_id])
    chat = account.chats.kept.find(params[:chat_id])
    through = chat.messages.kept.find(params.require(:through_message_id))
    ReplyDismissal.dismiss!(chat: chat, user: Current.user, through: through)
    audit("dismiss_reply_expectations", chat, through_message_id: through.to_param)
    redirect_back fallback_location: account_chat_path(account, chat), allow_other_host: false, status: :see_other
  end

end
