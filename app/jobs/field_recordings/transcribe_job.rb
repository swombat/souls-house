# Sends an admitted recording to Scribe (spec §5). The claim, the response and
# any error each run under the lifecycle guards in FieldRecording::Transcription,
# so a late answer for an attempt that's no longer current changes nothing.
module FieldRecordings
  class TranscribeJob < ApplicationJob

    queue_as :default

    BACKOFF = [ 1.minute, 5.minutes, 15.minutes ].freeze
    SOURCE_URL_TTL = 6.hours

    def perform(recording_id, client: ElevenLabsScribe.new, configured: ElevenLabsScribe.configured?)
      # Fail closed: without the key, webhook and secret, nothing is sent and
      # no attempt is used. The recording waits in `queued`; the sweep sends
      # it once configuration exists.
      return unless configured

      recording = FieldRecording.find_by(id: recording_id)
      dispatch = recording&.claim_dispatch!
      return unless dispatch

      submission = with_source(recording) do |source|
        client.submit(
          metadata: { recording: recording.to_param, attempt: dispatch.attempt_token },
          num_speakers: recording.expected_speakers,
          keyterms: TranscriptionGlossary.keyterms_for(recording.account),
          **source
        )
      end
      recording.record_submission!(dispatch, submission)
    rescue ElevenLabsScribe::PermanentError => e
      recording.attempt_failed!(dispatch, e.message, permanent: true)
    rescue ElevenLabsScribe::TransientError => e
      if recording.attempt_failed!(dispatch, e.message, permanent: false) == :requeued
        self.class.set(wait: BACKOFF.fetch(recording.dispatch_count - 1, BACKOFF.last)).perform_later(recording.id)
      end
    end

    private

    # S3 in production: Scribe fetches a short-lived signed URL. Local disk
    # storage (development) has no URL Scribe can reach, so the bytes are sent.
    # The disk service class is only loaded when a disk service is configured,
    # so naming it bare raises NameError in production; `defined?` doesn't.
    def with_source(recording)
      blob = recording.audio.blob
      if defined?(ActiveStorage::Service::DiskService) && blob.service.is_a?(ActiveStorage::Service::DiskService)
        blob.open { |file| yield(file:) }
      else
        yield(source_url: blob.url(expires_in: SOURCE_URL_TTL, disposition: :attachment))
      end
    end

  end
end
