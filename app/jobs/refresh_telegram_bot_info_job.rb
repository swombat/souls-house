# Reads BotFather's privacy mode for a resident's bot (getMe), so its
# settings can say when Telegram is still withholding a group's untagged
# messages. Run when the webhook is set and whenever group membership moves.
class RefreshTelegramBotInfoJob < ApplicationJob

  queue_as :default

  def perform(agent)
    agent.refresh_telegram_bot_info!
  end

end
