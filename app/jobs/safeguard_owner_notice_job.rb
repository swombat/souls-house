class SafeguardOwnerNoticeJob < ApplicationJob

  queue_as :default

  discard_on ActiveJob::DeserializationError

  # Retained so previously queued unsolicited Telegram notices drain safely.
  # Safeguard detection, review and direct replies remain active.
  def perform(_detection)
  end

end
