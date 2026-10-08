# Naming a speaker on one recording (spec §7). Exactly one way per request:
#
#   me: true               the current user's own voice (made on first use)
#   voice_id: <id>         an existing voice in this account
#   member_user_id: <id>   an account member who has no voice yet
#   name: "Priya"          a new voice; if a voice of that name exists, the
#                          page is asked "same Priya?" unless link_existing
#   unname: true           back to "Speaker N"
#
# Naming never touches other recordings, and never builds anything biometric.
class FieldRecordingSpeakersController < ApplicationController

  require_feature_enabled :agents
  before_action :set_speaker

  def update
    attributes = params.require(:speaker).permit(:me, :voice_id, :member_user_id, :name, :link_existing, :unname,
      :confirm_suggestion, :dismiss_suggestion, :suggestion_generation)

    if truthy?(attributes[:unname])
      @speaker.unname!
    elsif truthy?(attributes[:dismiss_suggestion])
      return out_of_date unless @speaker.dismiss_suggestion!(attributes[:suggestion_generation])
    elsif truthy?(attributes[:confirm_suggestion])
      confirmed = confirm_suggestion(attributes)
      return if performed?
      return out_of_date unless confirmed
    else
      voice = resolve_voice(attributes)
      return if performed?

      @speaker.name_as!(voice, by: Current.user)
    end
    redirect_to recording_path
  rescue ActiveRecord::RecordInvalid => e
    redirect_to recording_path, inertia: { errors: { name: e.record.errors.full_messages.to_sentence } }
  end

  private

  def set_speaker
    recording = current_account.field_recordings.kept.find(params[:field_recording_id])
    # Association finders decode with the owner's salt, so decode explicitly.
    @speaker = recording.speakers.find_by!(id: FieldRecordingSpeaker.decode_id(params[:id]))
  end

  def recording_path
    account_field_recording_path(current_account, @speaker.field_recording)
  end

  def resolve_voice(attributes)
    voices = current_account.field_voices.kept
    if truthy?(attributes[:me])
      FieldVoice.for_member!(account: current_account, user: Current.user, by: Current.user)
    elsif attributes[:voice_id].present?
      voices.find_by!(id: FieldVoice.decode_id(attributes[:voice_id]))
    elsif attributes[:member_user_id].present?
      FieldVoice.for_member!(account: current_account, user: current_account.users.find(attributes[:member_user_id]), by: Current.user)
    elsif attributes[:name].present?
      existing = voices.named_like(attributes[:name]).first
      return voices.create!(name: attributes[:name], created_by: Current.user) unless existing
      return existing if truthy?(attributes[:link_existing])

      redirect_to recording_path, inertia: { errors: { name_match: match_json(existing) } }
      nil
    else
      redirect_to recording_path, inertia: { errors: { name: "Choose who this is." } }
      nil
    end
  end

  # Under the recording lock: the chip the person saw must still be the live
  # suggestion (same generation, no decision since). The suggested name then
  # goes through exactly the same check as a typed one, so a name matching a
  # known voice asks "same Priya?" before linking.
  def confirm_suggestion(attributes)
    @speaker.field_recording.with_lock do
      next false unless @speaker.suggestion_current?(attributes[:suggestion_generation])

      voice = resolve_voice(attributes.merge(name: @speaker.suggested_name))
      next nil if performed?

      @speaker.name_as!(voice, by: Current.user, source: "confirmed_suggestion")
      true
    end
  end

  def out_of_date
    redirect_to recording_path, inertia: { errors: { name: "This suggestion is out of date." } }
  end

  def match_json(voice)
    { voice_id: voice.to_param, name: voice.name, last_named_in: voice.last_named_in&.title }.to_json
  end

  def truthy?(value) = ActiveModel::Type::Boolean.new.cast(value) == true

end
