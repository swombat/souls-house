class AbandonedAppUploadsJob < ApplicationJob

  queue_as :default

  BATCH_SIZE = 100
  RETENTION = 24.hours

  # Unsent uploads by metadata tag, and how long each is kept. Chat voice notes
  # stay longer so a failed transcription can still be retried the next day.
  SWEEPS = { "app_upload" => RETENTION, VoiceNote::METADATA_KEY => VoiceNote::RETENTION }.freeze

  def perform(now: Time.current)
    SWEEPS.each { |tag, retention| sweep(tag, now - retention) }
  end

  private

  def sweep(tag, cutoff)
    # Active Storage serializes metadata as JSON in a text column. Cast
    # explicitly so nested keys cannot fill the batch and starve real uploads.
    # Authority still comes from the parsed metadata checked under the lock.
    ids = ActiveStorage::Blob.unattached
      .where(created_at: ...cutoff)
      .where("metadata::jsonb ? :tag", tag: tag)
      .order(:id).limit(BATCH_SIZE).pluck(:id)

    ids.each do |id|
      deleted = ActiveStorage::Blob.transaction do
        blob = ActiveStorage::Blob.lock("FOR UPDATE SKIP LOCKED").find_by(id: id)
        next unless blob && blob.metadata.key?(tag) && blob.created_at < cutoff
        next if ActiveStorage::Attachment.exists?(blob_id: blob.id)

        blob.destroy!
        blob
      end

      # Commit the removal before touching storage: claimers must observe a
      # missing row, never a rollback that resurrects a blob without its bytes.
      # Blob#delete also removes image variants, as Blob#purge does.
      deleted&.delete
    rescue StandardError => error
      # A bad row or unavailable object must not prevent the rest of the
      # batch from being cleaned. Do not log keys, filenames or service errors.
      Rails.logger.error "[AbandonedAppUploadsJob] blob_id=#{id} cleanup failed: #{error.class}"
    end
  end

end
