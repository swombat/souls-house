class ManageTelegramWebhookJob < ApplicationJob

  queue_as :default

  def perform(agent)
    if agent.telegram_configured?
      agent.set_telegram_webhook!
      agent.refresh_telegram_bot_info!
    else
      agent.delete_telegram_webhook!
    end
  end

end
