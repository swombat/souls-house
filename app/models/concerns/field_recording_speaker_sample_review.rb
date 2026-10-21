module FieldRecordingSpeakerSampleReview

  extend ActiveSupport::Concern

  included do
    belongs_to :sample_confirmed_by, class_name: "User", optional: true
  end

  # The sample and digest are the ones the person saw. Exclusion is also
  # possible for a legacy sample, or before the first sample has landed.
  def review_sample!(sample:, digest:, by:, included:)
    raise ArgumentError, "a user must review the sample" unless by.is_a?(User) && by.persisted?

    with_sample_review_locks do |recording, _voices|
      current = sample ? voice_samples.find_by(id: sample.id) : voice_samples.first
      next false unless recording.kept? && recording.ready?
      next false unless current&.id == sample&.id && current&.source_digest == digest
      next false if included && !(current && field_voice&.kept? && digest.present? && current.source_current?)

      attributes = { sample_excluded: !included, sample_review_generation: sample_review_generation + 1,
        sample_learning_status: current ? "learned" : nil, sample_learning_error: nil }
      if included
        attributes.merge!(sample_confirmed_digest: digest, sample_confirmed_by: by, sample_confirmed_at: Time.current)
      end
      update!(attributes)
      # Review changes membership, not extraction recency or profile priority.
      voice_samples.update_all(eligible: false)
      current.update_columns(eligible: true) if included
      FieldVoiceprints::Learning.sample_voices([ id ]).each { |voice| FieldVoiceprints::Learning.rebuild!(voice) }
      true
    end
  end

  # A fresh extraction may be requested even while excluded, but it cannot
  # enroll the resulting sample. Keep the previous sample until replacement.
  def relearn_sample!
    with_sample_review_locks do |_recording, _voices|
      next false unless FieldVoiceprints::Learning.snapshot_for(self, allow_excluded: true)

      update!(sample_review_generation: sample_review_generation + 1,
        sample_learning_status: "pending", sample_learning_error: nil)
      snapshot = FieldVoiceprints::Learning.snapshot_for(self, allow_excluded: true)
      ActiveRecord.after_all_transactions_commit { FieldVoices::LearnSampleJob.perform_later(snapshot) }
      true
    end
  end

  private

  def with_sample_review_locks
    voices = [ field_voice, *FieldVoiceprints::Learning.sample_voices([ id ]) ].compact
    FieldVoiceprints::Locks.with(account: field_recording.account, recording: field_recording, voices:) do |_account, recording, locked|
      reload
      needed = [ field_voice_id, *voice_samples.pluck(:field_voice_id) ].compact.uniq
      next false unless (needed - locked.map(&:id)).empty?

      yield recording, locked
    end
  end

end
