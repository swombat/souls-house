class Chats::WorkStatusesController < ApplicationController

  include WorkStatusResponse
  require_feature_enabled :chats

  def update
    @chat = Chat.kept.where(account_id: Current.user.confirmed_accounts.select(:id))
      .where(account_id: current_account.id).find(params[:chat_id])
    update_work_status(user: Current.user)
  end

end
