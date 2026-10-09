class Chats::TranscriptionsController < ApplicationController

  include ChatScoped

  skip_before_action :set_chat, unless: -> { params[:chat_id].present? }
  before_action :require_respondable_chat, if: -> { params[:chat_id].present? }

  def create
    audio = params.require(:audio)
    text = ElevenLabsStt.transcribe(audio, keyterms: TranscriptionGlossary.keyterms_for(transcription_account))

    if text.present?
      audio.tempfile.rewind
      blob = ActiveStorage::Blob.create_and_upload!(
        io: audio.tempfile,
        filename: audio.original_filename || "recording.webm",
        content_type: audio.content_type || "audio/webm"
      )

      render json: { text: text, audio_signed_id: blob.signed_id }
    else
      render json: { error: "No speech detected" }, status: :unprocessable_entity
    end
  rescue ElevenLabsStt::Error => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  # The room's account, or the account the person is working in when the
  # recording isn't for a room yet.
  def transcription_account
    @chat&.account || current_account
  end

end
