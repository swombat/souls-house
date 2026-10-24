# Learns one speaker's sample for the voice a person named them as
# (FieldVoiceprints::Learning). The voice service being down is retried; any
# other outcome (learned, stale, too little clean speech) is final.
module FieldVoices
  class LearnSampleJob < ApplicationJob

    queue_as :background

    retry_on FieldVoiceprints::VoiceEmbeddings::Unavailable, wait: :polynomially_longer, attempts: 6

    def perform(snapshot)
      return unless FieldVoiceprints::Learning.set_status!(snapshot, "pending")
      FieldVoiceprints::Learning.learn!(snapshot)
    end

  end
end
