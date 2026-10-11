# Naming a speaker on one recording (spec §7). Exactly one way per request:
#
#   me: true               the current user's own voice (made on first use)
#   voice_id: <id>         an existing voice in this account
#   member_user_id: <id>   an account member who has no voice yet
#   name: "Priya"          a new voice; if a voice of that name exists, the
#                          page is asked "same Priya?" unless link_existing
#   unname: true           back to "Speaker N"
#
# with: [<speaker id>, ...] applies the naming (or unnaming) to other speakers
# on this recording linked to the same voice as this one: the transcriber
# heard one person as several speakers, and the page shows them as one.
#
# Naming never touches other recordings, and never builds anything biometric.
class FieldRecordingSpeakersController < ApplicationController

  require_feature_enabled :agents
  before_action :set_speaker

  def update
    attributes = params.require(:speaker).permit(:me, :voice_id, :member_user_id, :name, :link_existing, :unname,
      :confirm_suggestion, :dismiss_suggestion, :suggestion_generation, :confirm_recognition, :dismiss_recognition,
      recognition: %i[voice_id print_generation decision_generation], with: [])
    companion_ids = decode_ids(attributes[:with])

    if truthy?(attributes[:unname])
      with_companions(companion_ids) do |companions|
        @speaker.unname!
        companions.each(&:unname!)
      end
    elsif truthy?(attributes[:dismiss_recognition])
      return out_of_date unless @speaker.dismiss_recognition!(shown: attributes[:recognition])
    elsif truthy?(attributes[:confirm_recognition])
      return out_of_date unless @speaker.confirm_recognition!(by: Current.user, shown: attributes[:recognition])
    elsif truthy?(attributes[:dismiss_suggestion])
      return out_of_date unless @speaker.dismiss_suggestion!(attributes[:suggestion_generation])
    elsif truthy?(attributes[:confirm_suggestion])
      confirmed = confirm_suggestion(attributes)
      return if performed?
      return out_of_date unless confirmed
    else
      voice = resolve_voice(attributes)
      return if performed?

      with_companions(companion_ids, voices: [ voice ]) do |companions|
        @speaker.name_as!(voice, by: Current.user)
        companions.each { |companion| companion.name_as!(voice, by: Current.user) }
      end
    end
    return out_of_date(STALE_GROUP) if @stale_group

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

  STALE_GROUP = "This person changed since the page loaded. Please look again."

  def decode_ids(ids) = Array(ids).filter_map { |id| FieldRecordingSpeaker.decode_id(id.to_s) }

  # A merged card's decision, made as one. The group is chosen under the
  # naming locks (account → recording → voices) and the whole batch is one
  # transaction, so nothing can change membership between choosing and
  # writing, and a part that can't be updated rolls back the rest. Companions
  # are only speakers on this recording still linked to the voice this one
  # had when the request arrived: one corrected to someone else in the
  # meantime keeps that correction. If this speaker itself has moved, the
  # page was stale and nothing changes.
  def with_companions(ids, voices: [])
    return yield([]) if ids.empty?

    shown_voice_id = @speaker.field_voice_id
    return yield([]) if shown_voice_id.nil?

    FieldVoiceprints::Locks.with(account: current_account, recording: @speaker.field_recording,
      voices: [ *voices, FieldVoice.find_by(id: shown_voice_id) ].compact) do |_account, recording, _voices|
      @speaker.reload
      next @stale_group = true unless @speaker.field_voice_id == shown_voice_id

      yield recording.speakers.where(id: ids, field_voice_id: shown_voice_id).where.not(id: @speaker.id).order(:id).to_a
    end
  end

  def recording_path
    account_field_recording_path(current_account, @speaker.field_recording)
  end

  def resolve_voice(attributes)
    choice = FieldVoice::Choice.resolve(
      account: current_account, user: Current.user,
      me: truthy?(attributes[:me]), voice_id: attributes[:voice_id], member_user_id: attributes[:member_user_id],
      name: attributes[:name], link_existing: truthy?(attributes[:link_existing])
    )
    return choice.voice if choice.voice

    if choice.match
      redirect_to recording_path, inertia: { errors: { name_match: match_json(choice.match) } }
    else
      redirect_to recording_path, inertia: { errors: { name: "Choose who this is." } }
    end
    nil
  end

  # Under account → recording (the naming order, never recording first): the chip the person saw must still be the live
  # suggestion (same generation, no decision since). The suggested name then
  # goes through exactly the same check as a typed one, so a name matching a
  # known voice asks "same Priya?" before linking.
  def confirm_suggestion(attributes)
    @speaker.with_decision_locks do
      next false unless @speaker.suggestion_current?(attributes[:suggestion_generation])

      voice = resolve_voice(attributes.merge(name: @speaker.suggested_name))
      next nil if performed?

      @speaker.name_as!(voice, by: Current.user, source: "confirmed_suggestion")
      true
    end
  end

  def out_of_date(message = "This suggestion is out of date.")
    redirect_to recording_path, inertia: { errors: { name: message } }
  end

  def match_json(voice)
    { voice_id: voice.to_param, name: voice.name, last_named_in: voice.last_named_in&.title }.to_json
  end

  def truthy?(value) = ActiveModel::Type::Boolean.new.cast(value) == true

end
