class Chats::ReplyDismissalsController < ApplicationController

  def create
    # Unlike site-admin browsing, reply attention requires actual membership.
    account = Current.user.confirmed_accounts.find(params[:account_id])
    chat = account.chats.kept.find(params[:chat_id])
    if params[:message_id].present?
      return head :bad_request if params[:through_message_id].present?
      message = chat.messages.kept.find(params[:message_id])
      ReplyExpectation.dismiss_message!(message: message, user: Current.user)
      audit("dismiss_reply_expectation", chat, message_id: message.to_param)
    else
      through = chat.messages.kept.find(params.require(:through_message_id))
      ReplyDismissal.dismiss!(chat: chat, user: Current.user, through: through)
      audit("dismiss_reply_expectations", chat, through_message_id: through.to_param)
    end
    redirect_back fallback_location: account_chat_path(account, chat), allow_other_host: false, status: :see_other
  end

end
