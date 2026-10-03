module ChatScoped

  extend ActiveSupport::Concern
  include RespondableChat

  included do
    require_feature_enabled :chats
    before_action :set_chat
  end

  private

  def set_chat
    # Use with_discarded to allow admins to find discarded chats for restore
    @chat = current_account.chats.with_discarded.find(params[:chat_id])
  end

end
