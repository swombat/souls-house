# Turns a voice note into composer text.
#
# The original recording is stored before ElevenLabs is asked, so a provider
# error, timeout or "no speech" leaves a saved recording the person can retry
# (POST with `audio_signed_id` instead of `audio`) or discard (DELETE). Nothing
# here sends a message: success only returns text for the composer. A recording
# already attached to a message cannot be retried, so a retry cannot duplicate
# a sent message. Unsent recordings are swept by AbandonedAppUploadsJob.
class Chats::TranscriptionsController < ApplicationController

  include ChatScoped

  skip_before_action :set_chat, unless: -> { params[:chat_id].present? }
  before_action :require_respondable_chat, if: -> { params[:chat_id].present? }

  NO_SPEECH = "No speech detected".freeze
  NOT_SAVED = "The recording could not be saved. It is still in this tab; keep it open and try again.".freeze
  GONE = "That recording is no longer available.".freeze
  TOO_LARGE = "The recording is too large to save.".freeze
  UNREADABLE = "The saved recording could not be read just now. It is still saved; try again.".freeze

  def create
    if params[:audio_signed_id].present?
      blob = owned_recording or return
      text = transcribe_stored(blob)
      return render_gone if text == :gone
    else
      audio = params.require(:audio)
      blob = store_recording(audio) or return
      audio.tempfile.rewind
      text = ElevenLabsStt.transcribe(audio, keyterms: keyterms)
    end

    if text.present?
      render json: { text: text, audio_signed_id: blob.signed_id }
    else
      render_failed(blob, NO_SPEECH)
    end
  rescue ElevenLabsStt::Error => e
    render_failed(blob, e.message)
  end

  def destroy
    blob = owned_recording or return

    case VoiceNote.discard!(blob)
    when true then head :no_content
    when false then render_gone
    else render json: { error: "That recording has already been sent.", retryable: false }, status: :conflict
    end
  end

  private

  # The room's account, or the account the person is working in when the
  # recording isn't for a room yet.
  def transcription_account
    @chat&.account || current_account
  end

  def keyterms
    TranscriptionGlossary.keyterms_for(transcription_account)
  end

  def store_recording(audio)
    if audio.size > Message::Attachable::MAX_FILE_SIZE
      render json: { error: TOO_LARGE, retryable: false, saved: false }, status: :content_too_large
      return
    end

    audio.tempfile.rewind
    ActiveStorage::Blob.create_and_upload!(
      io: audio.tempfile,
      filename: audio.original_filename.presence || "recording.webm",
      content_type: audio.content_type.presence || "audio/webm",
      metadata: { VoiceNote::METADATA_KEY => VoiceNote.metadata_for(user: Current.user, account: transcription_account, chat: @chat) }
    )
  rescue StandardError => e
    # The bytes never became a durable recording; say so rather than pretend.
    Rails.logger.error "[Transcriptions] recording could not be stored: #{e.class}"
    render json: { error: NOT_SAVED, retryable: true, saved: false }, status: :service_unavailable
    nil
  end

  # A saved, unsent recording made by this person in this account. Everything
  # else (bad signature, someone else's, another account, already sent, not a
  # voice note) is the same 404.
  def owned_recording
    blob = ActiveStorage::Blob.find_signed(params[:audio_signed_id].to_s)
    return blob if blob && VoiceNote.retryable_by?(blob, user: Current.user, account: transcription_account, chat: @chat)

    render_gone
    nil
  end

  def render_gone
    render json: { error: GONE, retryable: false, saved: false }, status: :not_found
  end

  def transcribe_stored(blob)
    blob.open do |file|
      upload = ActionDispatch::Http::UploadedFile.new(tempfile: file, filename: blob.filename.to_s, type: blob.content_type)
      ElevenLabsStt.transcribe(upload, keyterms: keyterms)
    end
  rescue ActiveStorage::FileNotFoundError, ActiveStorage::IntegrityError => e
    # Discarded or swept while we were reading it: say so, never "still saved".
    return :gone unless ActiveStorage::Blob.exists?(blob.id)

    Rails.logger.error "[Transcriptions] saved recording unreadable: #{e.class}"
    raise ElevenLabsStt::Error, UNREADABLE
  end

  # Claims the recording is saved only if it still is: a discard or sweep that
  # ran while ElevenLabs was busy turns the failure into "no longer available".
  def render_failed(blob, message)
    return render_gone unless ActiveStorage::Blob.exists?(blob.id)

    render json: { error: message, retryable: true, saved: true, audio_signed_id: blob.signed_id,
                   expires_at: VoiceNote.expires_at(blob).iso8601 },
      status: :unprocessable_entity
  end

end
