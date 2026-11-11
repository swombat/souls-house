class Chats::WorkCompletionsController < ApplicationController

  include WorkCompletionResponse
  require_feature_enabled :chats

  %w[show create accept grant revoke close].each do |action|
    define_method(action) do
      @chat = Chat.kept.where(account_id: Current.user.confirmed_accounts.select(:id))
        .where(account_id: current_account.id).find(params[:chat_id])
      perform_completion_action(action, user: Current.user)
    end
  end

end
