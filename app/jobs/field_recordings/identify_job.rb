# Guesses who a ready recording's unnamed speakers are, from the prints this
# Field has learned (FieldVoiceprints::Identification). The voice service
# being down is retried; a guess is only ever a chip.
module FieldRecordings
  class IdentifyJob < ApplicationJob

    queue_as :background

    retry_on FieldVoiceprints::VoiceEmbeddings::Unavailable, wait: :polynomially_longer, attempts: 6

    # A print changed while this recording was being embedded: nothing was
    # written, so run again (its probes are kept by then only if nothing
    # revoked them). Bounded, in case prints keep changing.
    MAX_RERUNS = 3

    def perform(recording_id, rerun = 0)
      recording = FieldRecording.kept.find_by(id: recording_id)
      return unless recording&.ready?

      result = FieldVoiceprints::Identification.run!(recording)
      self.class.set(wait: 30.seconds).perform_later(recording_id, rerun + 1) if result == :changed && rerun < MAX_RERUNS
    end

  end
end
