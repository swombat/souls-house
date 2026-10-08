# Conversation actions a person's credential takes on their behalf, on top of
# ApiHumanActor: the web's chats feature gate (ChatScoped/MessagesController's
# require_feature_enabled :chats), and finding a room so that authority is
# always checked against that room's own account, never a default.
module ApiHumanConversation

  extend ActiveSupport::Concern

  CHATS_DISABLED = "Conversations are currently disabled".freeze

  private

  # before_action: the web refuses these actions while chats are switched off.
  def require_chats_feature!
    return if Setting.instance.allow_chats?

    render json: { error: CHATS_DISABLED, code: "feature_disabled" }, status: :forbidden
  end

  # A room among those the credential reaches (human_chats: the key's account,
  # or every enabled account of the token's person, or the one account_id
  # names), whose account the person currently belongs to and is enabled.
  # Otherwise 404.
  def human_chat!(relation = human_chats.kept, id = params[:conversation_id])
    chat = relation.find(id)
    human_account!(chat.account)
    chat
  end

end
