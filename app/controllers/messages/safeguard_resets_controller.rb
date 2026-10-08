# "Start <resident> fresh again" on a labelled safeguard message (spec §4).
# Any member who can see the room asks; the resident's next trigger in this
# conversation starts a fresh session. Repeat presses are harmless.
class Messages::SafeguardResetsController < Messages::BaseController

  include RespondableChat

  before_action :require_respondable_chat

  def create
    detection = @message.safeguard_detection
    chat_agent = detection && @chat.chat_agents.find_by(agent_id: @message.agent_id)
    return render json: { error: "This message has no safeguard label" }, status: :unprocessable_entity unless chat_agent

    SafeguardRoll.request_reset!(chat_agent)
    render json: { confirmation: SafeguardNoticeRenderer.reset_confirmation(@message.agent) }, status: :created
  end

end
