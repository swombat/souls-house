class TelegramNotificationJob < ApplicationJob

  queue_as :default

  discard_on ActiveJob::DeserializationError

  # Retained so notifications queued before automatic chat notifications were
  # removed can drain safely, including jobs whose records no longer exist.
  def perform(_subscription, _message, _chat)
  end

end
