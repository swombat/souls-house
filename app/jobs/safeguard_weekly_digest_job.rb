class SafeguardWeeklyDigestJob < ApplicationJob

  queue_as :default

  # Retained so previously queued unsolicited Telegram digests drain safely.
  # Safeguard detection records remain available for review.
  def perform
  end

end
