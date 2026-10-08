# Every ten minutes (spec §5):
#
# - a recording transcribing too long with no webhook: fetch the transcript if
#   its id is known, otherwise abandon the attempt (requeue within the cap);
# - abandoned or superseded attempts with a known transcript id and no
#   cleanup started get one (vendor deletion's safety net);
# - pending reservations stranded on rejected or failed recordings are
#   released; on discarded ones they settle by the discard rule (consumed if
#   anything was dispatched, released if not);
# - queued recordings with no live job are sent again (the claim keeps the cap).
module FieldRecordings
  class StuckSweepJob < ApplicationJob

    queue_as :default

    MIN_WAIT = 20.minutes
    ORPHAN_QUEUED_AFTER = 30.minutes
    RECONCILE_AFTER = 30.minutes
    NO_RESULT = "No result arrived from the transcriber."

    def perform(now: Time.current, client: ElevenLabsScribe.new)
      chase_stuck(now, client)
      reconcile_cleanup(now)
      settle_stranded(now)
      requeue_orphans(now)
    end

    private

    def chase_stuck(now, client)
      FieldRecording.kept.where(status: "transcribing").find_each do |recording|
        dispatch = recording.current_dispatch
        next unless dispatch
        next if dispatch.created_at > now - wait_for(recording)

        if dispatch.transcription_id.present? && fetched(recording, dispatch, client)
          next
        end

        if recording.attempt_failed!(dispatch, NO_RESULT, permanent: false) == :requeued
          TranscribeJob.perform_later(recording.id)
        end
      end
    end

    def fetched(recording, dispatch, client)
      transcription = client.fetch(dispatch.transcription_id)
      return false unless transcription["words"].is_a?(Array)

      FieldRecording::TranscriptReceiver.receive!(dispatch, transcription)
      true
    rescue ElevenLabsScribe::Error
      false
    end

    # Safety net for vendor cleanup (spec §5): any abandoned or superseded
    # attempt with a known transcript id and no cleanup started gets one.
    def reconcile_cleanup(now)
      FieldRecordingDispatch.awaiting_cleanup.where(updated_at: ...(now - RECONCILE_AFTER)).find_each(&:queue_cleanup)
    end

    def wait_for(recording)
      [ MIN_WAIT, (recording.duration_ms.to_i / 2).seconds / 1000 ].max
    end

    def settle_stranded(now)
      FieldRecordingReservation.where(state: "pending").includes(:field_recording).find_each do |reservation|
        recording = reservation.field_recording
        if recording.discarded?
          recording.with_lock { recording.settle_reservation_after_discard!(now:) }
        elsif recording.rejected? || recording.failed?
          reservation.release!(reason: recording.status, now:)
        end
      end
    end

    def requeue_orphans(now)
      return unless ElevenLabsScribe.configured?

      FieldRecording.kept.where(status: "queued").where(updated_at: ...(now - ORPHAN_QUEUED_AFTER)).find_each do |recording|
        TranscribeJob.perform_later(recording.id)
      end
    end

  end
end
