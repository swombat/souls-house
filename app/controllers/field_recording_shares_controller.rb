# Links that let someone without an account read a recording's transcript
# (FieldRecordingShare). Any member who can open the recording can make one or
# revoke one. Making a link answers JSON with the URL: the token is in it and
# is never shown again, so it doesn't travel through the flash or a redirect.
class FieldRecordingSharesController < ApplicationController

  require_feature_enabled :agents
  before_action :set_field_recording

  def create
    share = FieldRecordingShare.issue!(recording: @field_recording, user: Current.user, expiry: params[:expiry].to_s)
    render json: { share: share.as_list_json.merge(url: shared_transcript_url(share.token)) }, status: :created
  rescue FieldRecordingShare::Invalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def destroy
    @field_recording.shares.find(FieldRecordingShare.decode_id(params[:id].to_s)).revoke!
    redirect_to account_field_recording_path(current_account, @field_recording), notice: "That link no longer works."
  end

  private

  def set_field_recording
    @field_recording = current_account.field_recordings.kept.find(params[:field_recording_id])
  end

end
