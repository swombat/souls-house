class ManageTelegramWebhookJob < ApplicationJob

  queue_as :default

  def perform(agent)
    if agent.telegram_configured?
      agent.set_telegram_webhook!
      agent.refresh_telegram_bot_info!
      # A newly linked bot wears the resident's picture, if it has one; a
      # resident without one leaves the bot's own photo alone.
      SyncTelegramBotPhotoJob.perform_later(agent, remove_when_missing: false) if agent.avatar.attached?
    else
      agent.delete_telegram_webhook!
    end
  end

end
