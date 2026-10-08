# Hourly cleanup of recording bytes nobody brought into the Field (spec §4):
#
# - direct uploads that were never claimed, once their pin has expired;
# - the audio of rejected recordings after a day, unless a retry shares it.
#
# Each purge takes the blob's row lock and rechecks under it, the same lock a
# claim takes, so a claim and a purge can't both win.
module FieldRecordings
  class OrphanSweepJob < ApplicationJob

    queue_as :default

    REJECTED_AUDIO_TTL = 24.hours

    def perform(now: Time.current)
      purge_unclaimed_uploads(now)
      purge_rejected_audio(now)
    end

    private

    def purge_unclaimed_uploads(now)
      candidates = ActiveStorage::Blob
        .where("active_storage_blobs.metadata LIKE ?", "%#{FieldRecording::Upload::METADATA_KEY}%")
        .where(created_at: ...(now - FieldRecording::Upload::TTL))
        .where.missing(:attachments)

      candidates.find_each do |candidate|
        ActiveStorage::Blob.transaction do
          blob = ActiveStorage::Blob.lock.find_by(id: candidate.id)
          next unless blob && FieldRecording::Upload.recording_upload?(blob)
          next if ActiveStorage::Attachment.exists?(blob_id: blob.id)

          blob.purge_later
        end
      end
    end

    def purge_rejected_audio(now)
      FieldRecording.where(status: "rejected").where(updated_at: ...(now - REJECTED_AUDIO_TTL))
        .joins(:audio_attachment).find_each do |recording|
        ActiveStorage::Blob.transaction do
          recording.lock!
          attachment = recording.audio_attachment
          next unless recording.rejected? && attachment

          blob = ActiveStorage::Blob.lock.find_by(id: attachment.blob_id)
          shared = ActiveStorage::Attachment.where(blob_id: attachment.blob_id).where.not(id: attachment.id).exists?
          attachment.delete
          blob&.purge_later unless shared
        end
      end
    end

  end
end
