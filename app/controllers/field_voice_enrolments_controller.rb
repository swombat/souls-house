# "Remember this voice" (spec §9): the person ticked the box (create), heard
# the sample and said "use it" (confirm), or said "not them" (destroy). Each
# step goes through FieldVoiceprints::Enrolments and its rechecks.
class FieldVoiceEnrolmentsController < ApplicationController

  require_feature_enabled :agents

  def create
    recording = current_account.field_recordings.kept.find(params[:field_recording_id])
    speaker = recording.speakers.find_by!(id: FieldRecordingSpeaker.decode_id(params[:speaker_id]))
    unless params.dig(:enrolment, :consent).to_s == "1"
      return redirect_to recording_path(recording), inertia: { errors: { enrolment: "Tick the box to remember this voice." } }
    end

    FieldVoiceprints::Enrolments.start!(speaker, by: Current.user)
    redirect_to recording_path(recording)
  rescue FieldVoiceprints::Enrolments::Refused => e
    redirect_to recording_path(recording), inertia: { errors: { enrolment: e.message } }
  end

  def confirm
    enrolment = find_enrolment
    FieldVoiceprints::Enrolments.dispatch!(enrolment)
    FieldVoices::CollectPrintJob.set(wait: FieldVoices::CollectPrintJob::POLL_EVERY).perform_later(enrolment.id)
    redirect_to recording_path(enrolment.field_recording_speaker.field_recording),
      notice: "Remembering #{enrolment.field_voice.name}'s voice. It's ready in a minute or two."
  rescue FieldVoiceprints::Enrolments::Refused => e
    redirect_to recording_path(enrolment.field_recording_speaker.field_recording), inertia: { errors: { enrolment: e.message } }
  rescue FieldVoiceprints::Enrolments::Uncertain
    redirect_to recording_path(enrolment.field_recording_speaker.field_recording),
      inertia: { errors: { enrolment: "We couldn't confirm the voice service received the sample. Nothing will be " \
                                      "remembered from it. You can tick the box again to try once more." } }
  end

  def destroy
    enrolment = find_enrolment
    recording = enrolment.field_recording_speaker.field_recording
    enrolment.destroy!
    redirect_to recording_path(recording)
  end

  private

  def find_enrolment
    current_account.field_voice_enrolments.find_by!(id: FieldVoiceEnrolment.decode_id(params[:id]))
  end

  def recording_path(recording)
    account_field_recording_path(current_account, recording)
  end

end
