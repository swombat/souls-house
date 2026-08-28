class RefreshTelegramWebhooksJob < ApplicationJob

  queue_as :default

  def perform
    Agent.where.not(telegram_bot_token: nil).find_each do |agent|
      ManageTelegramWebhookJob.perform_later(agent)
    end
  end

end
