# The prints that can take part in matching in one account, and digests of
# them (Mira's reviews of #474). A print's verdict depends on every other
# print it was measured against: their samples set its negatives, its margins
# and the false accepts into it. So a verdict is stamped with the digest of
# the whole cohort it was computed in, and a print may guess only while the
# cohort is still exactly that one. Any rebuild, Forget, deletion or Remember
# again anywhere in the account changes the digest.
#
# The cohort uses one service profile: the profile of the newest eligible
# sample, which is stable provenance (validating doesn't change it). Prints
# made with another profile take no part until they are learned again.
#
# A guess is stamped with the key: the cohort digest and which prints were
# active in it. It stands, and can be confirmed, only while the key is the
# same.
module FieldVoiceprints::Cohort

  module_function

  # Rows only ever gain higher ids, and validating writes no sample, so this
  # doesn't move unless something is learned.
  def profile(account)
    FieldVoiceSample.eligible.joins(:field_voice).merge(FieldVoice.kept)
      .where(account:, field_voices: { remember: true }).order(id: :desc).with_confirmation_sources
      .detect(&:preloaded_manually_confirmed?)&.profile ||
      FieldVoiceprint.where(account:).order(id: :desc).pick(:profile)
  end

  def prints(account)
    current = profile(account)
    return [] unless current

    candidates = FieldVoiceprint.joins(:field_voice).merge(FieldVoice.kept)
      .where(account:, profile: current, field_voices: { remember: true }).includes(:field_voice).order(:id).to_a
    eligible = FieldVoiceSample.with_confirmation_sources.where(field_voice_id: candidates.map(&:field_voice_id), eligible: true)
      .to_a.group_by(&:field_voice_id)
    candidates.select { |print|
      confirmed = FieldVoiceprints::Limits.confirmed_samples(print.field_voice, samples: eligible.fetch(print.field_voice_id, []))
        .select { |sample| sample.profile == print.profile }
      print.generation == print.field_voice.print_generation &&
        confirmed.size >= FieldVoiceprints::Limits::MIN_CONFIRMED &&
        print.sample_digest == FieldVoiceprints::Learning.digest(confirmed)
    }
  end

  def digest(prints)
    Digest::SHA256.hexdigest(prints.sort_by(&:id).map do |print|
      [ print.id, print.field_voice_id, print.generation, print.sample_digest, print.profile ].join(":")
    end.join(","))
  end

  # [active prints, key]: the validated prints stamped with this cohort, and
  # a key naming both the cohort and that active set.
  def active(account)
    all = prints(account)
    digest = digest(all)
    active = all.select { |print| print.validated && print.validated_digest == digest }
    [ active, key(digest, active) ]
  end

  def key(digest, active)
    Digest::SHA256.hexdigest([ digest, *active.map { |print| "#{print.id}:#{print.generation}" }.sort ].join("|"))
  end

end
