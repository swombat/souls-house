# Recordings in the Field (spec §4–§6). Creating claims a direct upload made
# through FieldRecordingUploadsController; nothing else can be attached.
class FieldRecordingsController < ApplicationController

  require_feature_enabled :agents
  before_action :set_field_recording, only: %i[show update destroy retry]

  # The transcript page (spec §7). Words are sent whole: the page renders turns
  # from them, and clicking a word seeks the audio.
  def show
    recording = @field_recording
    render inertia: "field/recordings/show", props: {
      recording: FieldItems.recording_json(recording).merge(
        audio_url: (rails_blob_path(recording.audio, disposition: :inline) if recording.audio.attached?),
        words: recording.ready? ? recording.transcript_words : [],
        language_code: recording.language_code,
        ready_at: recording.ready_at&.iso8601
      ),
      speakers: recording.speakers.includes(:field_voice).map { |speaker| FieldItems.speaker_json(speaker) },
      voices: FieldItems.voices_json(current_account),
      members_without_voice: FieldItems.members_without_voice_json(current_account, except: Current.user),
      my_voice_id: current_account.field_voices.kept.find_by(user: Current.user)&.to_param,
      show_you_hint: show_you_hint?(recording),
      account: current_account.as_json
    }
  end

  def create
    attributes = params.require(:field_recording).permit(:upload_id, :title, :note, :expected_speakers)
    recording = FieldRecording::Upload.claim!(
      account: current_account,
      user: Current.user,
      signed_id: attributes[:upload_id],
      attributes: attributes.slice(:title, :note, :expected_speakers).to_h.symbolize_keys
    )

    if recording
      FieldRecordings::ProbeJob.perform_later(recording.id)
      redirect_to account_field_path(current_account, tab: "recordings", item: "recording-#{recording.to_param}"),
        notice: "Brought into the Field. Checking the recording…"
    else
      redirect_to account_field_path(current_account, tab: "recordings"),
        inertia: { errors: { audio: "That upload can't be used. Please upload the file again." } }
    end
  rescue ActiveRecord::RecordInvalid => e
    redirect_to account_field_path(current_account, tab: "recordings"),
      inertia: { errors: { audio: e.record.errors.full_messages.to_sentence } }
  end

  def update
    if @field_recording.update(params.require(:field_recording).permit(:title, :note))
      redirect_to item_path(@field_recording)
    else
      redirect_to item_path(@field_recording), alert: @field_recording.errors.full_messages.to_sentence
    end
  end

  def destroy
    @field_recording.discard_and_settle!
    redirect_to account_field_path(current_account, tab: "recordings"), notice: "Deleted from the Field."
  end

  def retry
    recording = @field_recording.retry!(by: Current.user)
    FieldRecordings::ProbeJob.perform_later(recording.id)
    redirect_to item_path(recording), notice: "Trying again."
  rescue FieldRecording::NotRetryable
    redirect_to item_path(@field_recording), alert: "This recording can't be tried again."
  end

  # "Is one of these you?" is shown once, until dismissed or answered.
  def dismiss_you_hint
    Current.user.update_column(:field_you_hint_dismissed_at, Time.current)
    head :no_content
  end

  private

  def set_field_recording
    @field_recording = current_account.field_recordings.kept.find(params[:id])
  end

  def item_path(recording)
    account_field_path(current_account, tab: "recordings", item: "recording-#{recording.to_param}")
  end

  def show_you_hint?(recording)
    recording.ready? && recording.uploaded_by == Current.user && Current.user.field_you_hint_dismissed_at.nil? &&
      !current_account.field_voices.kept.exists?(user: Current.user)
  end

end
