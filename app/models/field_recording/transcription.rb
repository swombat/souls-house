# The vendor half of a recording's lifecycle (spec §5, §5a). Every step takes
# the recording's lock and acts only if the recording is still kept, in the
# expected status, and (for anything attempt-bound) on the current attempt.
# A step that fails its guard may still record vendor ids on its own dispatch
# and queue vendor cleanup; it changes nothing on the recording.
module FieldRecording::Transcription

  extend ActiveSupport::Concern

  included do
    has_many :dispatches, class_name: "FieldRecordingDispatch", dependent: :destroy
    has_many :speakers, -> { in_order }, class_name: "FieldRecordingSpeaker", dependent: :destroy
  end

  # Claim the next dispatch: queued → transcribing with a fresh attempt.
  # nil when there's nothing to dispatch (not queued, discarded, capped, or
  # the account's dispatch exposure is used up).
  #
  # Two bounds. Per recording, at most MAX_DISPATCHES attempts. Per account,
  # the audio sent to the vendor in the last 7 days (every committed dispatch,
  # whatever became of it, because a timed-out or failed attempt may still
  # have been billed) stays within FieldRecordingDispatch.exposure_limit_ms.
  # That second bound is what stops refunded failures from buying unbounded
  # vendor work across new recordings and retries. Account lock first, then
  # this row, so concurrent claims are serialised.
  def claim_dispatch!(now: Time.current)
    account.with_lock do
      lock!
      next nil unless kept? && queued?
      if dispatch_count >= FieldRecording::MAX_DISPATCHES
        fail_and_release!("The transcriber couldn't process this recording.")
        next nil
      end
      if FieldRecordingDispatch.exposure_ms(account, now:) + duration_ms.to_i > FieldRecordingDispatch.exposure_limit_ms(account)
        fail_and_release!(FieldRecordingDispatch::EXPOSURE_MESSAGE)
        next nil
      end

      token = SecureRandom.urlsafe_base64(24)
      update!(status: "transcribing", attempt_token: token, dispatch_count: dispatch_count + 1)
      dispatches.create!(attempt_token: token, account:, audio_ms: duration_ms.to_i)
    end
  end

  # On discard (under this recording's lock): anything still in flight will
  # never be accepted now, so it's superseded, and if its transcript id is
  # already known its vendor cleanup starts. A late id for it then queues
  # cleanup through learn_ids!. A succeeded dispatch is left as it is.
  def supersede_in_flight_dispatches!
    dispatches.where(outcome: "in_flight").find_each do |dispatch|
      dispatch.with_lock do
        next unless dispatch.outcome == "in_flight"

        dispatch.update!(outcome: "superseded")
        dispatch.queue_cleanup if dispatch.transcription_id.present? && dispatch.vendor_deleted_at.nil?
      end
    end
  end

  def current_dispatch
    attempt_token && dispatches.find_by(attempt_token:)
  end

  # The POST answered. Ids go on the dispatch whatever state the recording is
  # in now; nothing on the recording changes.
  def record_submission!(dispatch, submission)
    dispatch.learn_ids!(request_id: submission.request_id, transcription_id: submission.transcription_id)
  end

  # The POST failed, or the sweep gave up waiting. Returns :failed, :requeued
  # or :stale (the attempt is no longer current; the recording is untouched).
  def attempt_failed!(dispatch, message, permanent:)
    with_lock do
      dispatch.reload
      if dispatch.outcome == "in_flight"
        dispatch.update!(outcome: "failed", error: message.to_s.truncate(255))
        # The vendor may still finish it; if we know its id, clean it up.
        dispatch.queue_cleanup if dispatch.transcription_id.present?
      end
      next :stale unless current_attempt?(dispatch)

      if permanent || dispatch_count >= FieldRecording::MAX_DISPATCHES
        fail_and_release!(permanent ? message : "The transcriber couldn't process this recording.")
        :failed
      else
        update!(status: "queued", attempt_token: nil)
        :requeued
      end
    end
  end

  # A finished transcript arrived (webhook or sweep). Returns :accepted,
  # :superseded or :duplicate. Vendor cleanup is the caller's job in every
  # case, because a finished transcript exists at the vendor regardless.
  def accept_transcript!(dispatch, transcription, request_id: nil, now: Time.current)
    transcription = {} unless transcription.is_a?(Hash)
    dispatch.learn_ids!(request_id:, transcription_id: transcription["transcription_id"])

    with_lock do
      dispatch.reload
      next :duplicate if dispatch.outcome == "succeeded"

      unless current_attempt?(dispatch) && transcription["words"].is_a?(Array)
        dispatch.update!(outcome: "superseded")
        next :superseded
      end

      store_transcript!(transcription)
      dispatch.update!(outcome: "succeeded")
      reservation&.consume!(now:)
      :accepted
    end
  end

  def render_transcript_text
    names = speakers.includes(:field_voice).to_h { |speaker| [ speaker.label, speaker.display_name ] }
    FieldRecording::Transcript.render(transcript_words || [], names)
  end

  private

  def current_attempt?(dispatch)
    kept? && transcribing? && attempt_token.present? && attempt_token == dispatch.attempt_token
  end

  def store_transcript!(transcription)
    words = FieldRecording::Transcript.compact(transcription["words"])
    speakers.delete_all
    FieldRecording::Transcript.speakers(words).each { |attributes| speakers.create!(attributes) }
    speakers.reset
    self.transcript_words = words
    self.language_code = transcription["language_code"].to_s.presence
    self.transcript_text = render_transcript_text
    update!(status: "ready", ready_at: Time.current, attempt_token: nil, failure_reason: nil)
  end

  def fail_and_release!(message)
    update!(status: "failed", failure_reason: message.to_s.truncate(255), attempt_token: nil)
    reservation&.release!(reason: "failed")
  end

end
