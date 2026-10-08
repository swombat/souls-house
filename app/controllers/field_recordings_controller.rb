# Recordings in the Field (spec §4–§6). Creating claims a direct upload made
# through FieldRecordingUploadsController; nothing else can be attached.
class FieldRecordingsController < ApplicationController

  require_feature_enabled :agents
  before_action :set_field_recording, only: %i[update destroy retry]

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

  private

  def set_field_recording
    @field_recording = current_account.field_recordings.kept.find(params[:id])
  end

  def item_path(recording)
    account_field_path(current_account, tab: "recordings", item: "recording-#{recording.to_param}")
  end

end
