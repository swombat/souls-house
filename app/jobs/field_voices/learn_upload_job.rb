module FieldVoices
  class LearnUploadJob < ApplicationJob

    queue_as :background
    retry_on FieldVoiceprints::VoiceEmbeddings::Unavailable, wait: :polynomially_longer, attempts: 6

    def self.queue!(sample)
      sample.with_lock do
        return false unless sample.account.recognise_voices? && sample.field_voice.remember?
        return false if sample.embedding.present? || sample.removed_at.present? || sample.excluded? || sample.learning_status == "queued"

        sample.update!(learning_status: "queued", learning_error: nil)
        ActiveRecord.after_all_transactions_commit { perform_later(sample.id) }
        true
      end
    end

    def perform(id)
      sample = FieldVoiceSample.find_by(id:)
      return unless sample

      if !sample.account.recognise_voices?
        sample.with_lock { sample.update!(learning_status: "pending") unless sample.eligible? || sample.removed_at || sample.excluded? }
        return
      end
      FieldVoiceSamples::Uploads.learn!(sample)
    end

  end
end
