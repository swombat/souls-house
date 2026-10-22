# The voices this Field knows (spec §7, §9): rename (changes the name
# everywhere), delete the identity, forget a voice, remember it again, forget
# all voices, and the account's recognition setting. Forgetting is never gated.
class FieldVoicesController < ApplicationController

  require_feature_enabled :agents

  def index
    voices = current_account.field_voices.kept.includes(:user, :voiceprint).order(Arel.sql("lower(name)"))
    used = FieldRecordingSpeaker.where(field_voice_id: voices.map(&:id)).group(:field_voice_id).count
    active_ids = FieldVoiceprints::Identification.active_prints(current_account).map(&:id)
    samples = FieldVoiceSample.where(field_voice_id: voices.map(&:id), removed_at: nil).includes(:field_recording_speaker).group_by(&:field_voice_id)
    render inertia: "field/voices", props: {
      voices: voices.map { |voice|
        FieldItems.voice_page_json(voice, used.fetch(voice.id, 0), active_ids)
          .merge(sample_counts(samples.fetch(voice.id, [])))
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

  # "Merge with other speaker": this voice goes into the chosen one, which
  # keeps whichever of the two names was picked.
  def merge
    voice = find_voice
    other = current_account.field_voices.kept.find_by(id: FieldVoice.decode_id(params[:into]))
    return redirect_back_or_to(account_field_voices_path(current_account),
      inertia: { errors: { merge: "Choose another speaker to merge with." } }) unless other

    kept = voice.merge_into!(other, name: params[:name])
    redirect_to account_field_voices_path(current_account, voice: kept.to_param),
      notice: "#{voice.name} and #{other.name} are now one speaker: #{kept.name}."
  rescue FieldVoice::Merge::Refused => error
    redirect_back_or_to account_field_voices_path(current_account), inertia: { errors: { merge: error.message } }
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

  # One click for the whole roster: queue a rebuild of every sample that
  # can't be heard yet, so it gets recorded spans and a play button.
  def prepare_samples
    queued = FieldVoiceprints::Learning.prepare_account_for_review!(current_account)
    render json: { queued: }
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

  # Roster counts from stored columns only: no transcript, blob or source
  # check per sample. The samples list is the authority on each row.
  def sample_counts(rows)
    included = rows.select { |sample| sample.eligible? && !sample.field_recording_speaker&.sample_excluded? }
    confirmed = included.select do |sample|
      speaker = sample.field_recording_speaker
      if speaker
        sample.source_digest.present? && speaker.sample_confirmed_digest == sample.source_digest && speaker.sample_confirmed_by_id.present?
      else
        sample.confirmed_digest.present? && sample.confirmed_digest == sample.source_digest && sample.confirmed_by_id.present?
      end
    end
    {
      samples: rows.size,
      included_samples: included.size,
      confirmed_samples: confirmed.size,
      unconfirmed_samples: rows.count { |sample|
        !sample.excluded? && !sample.field_recording_speaker&.sample_excluded? &&
          !(sample.standalone? ? sample.confirmed_digest.present? : sample.field_recording_speaker&.sample_confirmed_digest.present?)
      },
      unprepared_samples: rows.count { |sample| sample.source_digest.blank? }
    }
  end

  def find_voice
    current_account.field_voices.kept.find_by!(id: FieldVoice.decode_id(params[:id]))
  end

end
