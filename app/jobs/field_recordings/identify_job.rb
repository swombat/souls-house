# Guesses who a ready recording's unnamed speakers are, from the prints this
# Field has learned (FieldVoiceprints::Identification). The voice service
# being down is retried; a guess is only ever a chip.
module FieldRecordings
  class IdentifyJob < ApplicationJob

    queue_as :background

    retry_on FieldVoiceprints::VoiceEmbeddings::Unavailable, wait: :polynomially_longer, attempts: 6

    def perform(recording_id)
      recording = FieldRecording.kept.find_by(id: recording_id)
      return unless recording&.ready?

      FieldVoiceprints::Identification.run!(recording)
    end

  end
end
