module ChatScoped

  extend ActiveSupport::Concern
  include RespondableChat

  included do
    require_feature_enabled :chats
    before_action :set_chat
  end

  private

  def set_chat
    @chat = current_account.chats.kept.find(params[:chat_id])
  end

end
