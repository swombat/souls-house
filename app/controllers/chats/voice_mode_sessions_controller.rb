# Opens a voice-mode transcription session for this conversation: answers with
# a short-lived OpenAI client secret the page uses to stream the microphone to
# OpenAI (VoiceMode::TranscriptionSecret). Asked again on every (re)connect.
#
# Refused, with the same status the message path gives, when the mode is off
# for the account or there is no OpenAI key: hiding the wave button is not the
# enforcement.
class Chats::VoiceModeSessionsController < ApplicationController

  include ChatScoped

  before_action :require_respondable_chat

  def create
    account = @chat.account
    status = VoiceMode.status_for(account)
    unless status.available
      return render json: { error: "Voice mode is not available in this account.", voice_mode: status }, status: :forbidden
    end

    render json: VoiceMode::TranscriptionSecret.mint(account)
  rescue VoiceMode::TranscriptionSecret::Error => e
    render json: { error: e.message, retryable: true }, status: :bad_gateway
  end

end
