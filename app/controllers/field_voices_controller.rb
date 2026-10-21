# The voices this Field knows (spec §7, §9): rename (changes the name
# everywhere), delete the identity, forget a voice, remember it again, forget
# all voices, and the account's recognition setting. Forgetting is never gated.
class FieldVoicesController < ApplicationController

  require_feature_enabled :agents

  def index
    voices = current_account.field_voices.kept.includes(:user, :voiceprint).order(Arel.sql("lower(name)"))
    used = FieldRecordingSpeaker.where(field_voice_id: voices.map(&:id)).group(:field_voice_id).count
    active_ids = FieldVoiceprints::Identification.active_prints(current_account).map(&:id)
    samples = FieldVoiceSample.where(field_voice_id: voices.map(&:id)).includes(:field_recording_speaker).group_by(&:field_voice_id)
    render inertia: "field/voices", props: {
      voices: voices.map { |voice|
        rows = samples.fetch(voice.id, [])
        FieldItems.voice_page_json(voice, used.fetch(voice.id, 0), active_ids).merge(
          included_samples: rows.count { |sample| sample.eligible? && !sample.field_recording_speaker.sample_excluded? },
          unconfirmed_samples: rows.count { |sample| !sample.manually_confirmed? })
      },
      recognise_voices: current_account.recognise_voices,
      house_recognition: FieldVoiceprints.house_enabled?,
      can_change_setting: current_account.manageable_by?(Current.user),
      account: current_account.as_json
    }
  end

  def update
    voice = find_voice
    if voice.update(params.require(:field_voice).permit(:name))
      redirect_back_or_to account_field_path(current_account, tab: "recordings")
    else
      redirect_back_or_to account_field_path(current_account, tab: "recordings"),
        inertia: { errors: { name: voice.errors.full_messages.to_sentence } }
    end
  end

  def destroy
    voice = find_voice
    voice.delete_identity!
    redirect_to account_field_voices_path(current_account), notice: "#{voice.name} is no longer a voice in this Field."
  end

  def forget
    voice = find_voice
    voice.forget!
    redirect_back_or_to account_field_voices_path(current_account), notice: "This Field has forgotten #{voice.name}'s voice."
  end

  def remember
    voice = find_voice
    voice.remember_again!
    redirect_back_or_to account_field_voices_path(current_account),
      notice: "This Field will learn #{voice.name}'s voice again from the names people give."
  end

  def forget_all
    FieldVoiceprints.forget_all!(current_account)
    redirect_to account_field_voices_path(current_account), notice: "This Field has forgotten every voice it remembered."
  end

  # Turning recognition on or off for the account. Takes the account lock, the
  # same lock learning and matching write under, so a change can't slip
  # between their check and their write. Off keeps what was learned, unused;
  # "Forget all voices" sits beside it.
  def recognition
    return head(:forbidden) unless current_account.manageable_by?(Current.user)

    enabled = ActiveModel::Type::Boolean.new.cast(params.require(:recognise_voices))
    current_account.with_lock { current_account.update!(recognise_voices: enabled) }
    redirect_to account_field_voices_path(current_account)
  end

  private

  def find_voice
    current_account.field_voices.kept.find_by!(id: FieldVoice.decode_id(params[:id]))
  end

end
