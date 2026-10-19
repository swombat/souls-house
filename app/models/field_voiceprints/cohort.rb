# The prints that can take part in matching in one account, and a digest of
# them (Mira's review of #474, finding 3). A print's verdict depends on every
# other print it was measured against: their samples set its negatives, its
# margins and the false accepts into it. So a verdict is stamped with the
# digest of the whole cohort it was computed in, and a print may guess only
# while the cohort is still exactly that one. Any rebuild, Forget, deletion or
# Remember again anywhere in the account changes the digest.
module FieldVoiceprints::Cohort

  module_function

  def prints(account)
    FieldVoiceprint.joins(:field_voice).merge(FieldVoice.kept)
      .where(account:, field_voices: { remember: true }).includes(:field_voice).order(:id).to_a
      .select { |print| print.generation == print.field_voice.print_generation }
  end

  def digest(prints)
    Digest::SHA256.hexdigest(prints.sort_by(&:id).map do |print|
      [ print.id, print.field_voice_id, print.generation, print.sample_digest, print.profile ].join(":")
    end.join(","))
  end

  # [active prints, cohort digest]: validated prints stamped with this cohort.
  def active(account)
    all = prints(account)
    digest = digest(all)
    [ all.select { |print| print.validated && print.validated_digest == digest }, digest ]
  end

end
