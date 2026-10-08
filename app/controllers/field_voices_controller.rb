# The voices this Field knows (spec §7, §9): rename (changes the name
# everywhere), delete the identity, forget a print, forget all prints, and the
# account's recognition setting. Forgetting is never gated.
class FieldVoicesController < ApplicationController

  require_feature_enabled :agents

  def index
    voices = current_account.field_voices.kept.includes(:user, :voiceprint).order(Arel.sql("lower(name)"))
    used = FieldRecordingSpeaker.where(field_voice_id: voices.map(&:id)).group(:field_voice_id).count
    render inertia: "field/voices", props: {
      voices: voices.map { |voice| FieldItems.voice_page_json(voice, used.fetch(voice.id, 0)) },
      recognise_voices: current_account.recognise_voices,
      house_recognition: FieldVoiceprints.house_enabled?,
      can_change_setting: current_account.manageable_by?(Current.user),
      backup_retention_days: FieldVoiceprints.backup_retention_days,
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

  def forget_all
    FieldVoiceprints.forget_all!(current_account)
    redirect_to account_field_voices_path(current_account), notice: "This Field has forgotten every voice it remembered."
  end

  # Turning recognition on or off for the account. Takes the account lock, the
  # same lock identify and print write-back take, so a change can't slip
  # between their check and their send. Off keeps stored prints, unused;
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
