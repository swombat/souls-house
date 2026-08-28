class SafeguardDetectionRetentionJob < ApplicationJob

  queue_as :default

  def perform
    pending_detection_ids = TelegramSubscription
      .where.not(pending_safeguard_detection_id: nil)
      .select(:pending_safeguard_detection_id)
    now = Time.current

    SafeguardDetection
      .where(response_text_redacted_at: nil)
      .where("created_at < ?", SafeguardDetection::RESPONSE_TEXT_RETENTION.ago)
      .where.not(id: pending_detection_ids)
      .in_batches
      .update_all(response_text: nil, response_text_redacted_at: now, updated_at: now)
  end

end
