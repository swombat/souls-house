class TelegramNotificationJob < ApplicationJob

  queue_as :default

  retry_on TelegramNotifiable::TelegramError, wait: 30.seconds, attempts: 2

  def perform(subscription, message, chat)
    return if subscription.blocked?

    agent = subscription.agent
    return unless agent.telegram_configured?

    preview = message.content.to_s.truncate(300)
    public_url = Rails.configuration.x.public_url

    text = <<~HTML.strip
      <b>#{ERB::Util.html_escape(agent.name)}</b> in "#{ERB::Util.html_escape(chat.title_or_default)}"

      #{ERB::Util.html_escape(preview)}
    HTML

    # There's no request here to fall back to (unlike the controller call
    # sites for public_url), and the message content matters more than the
    # button — so a missing SOULSHOUSE_PUBLIC_URL drops the link rather than
    # failing the whole notification.
    options = {}
    if public_url.present?
      chat_url = "#{public_url}/accounts/#{chat.account_id}/chats/#{chat.to_param}"
      options[:reply_markup] = { inline_keyboard: [ [ { text: "Open Conversation", url: chat_url } ] ] }
    else
      Rails.logger.warn("[Telegram] SOULSHOUSE_PUBLIC_URL is not set; sending notification without an Open Conversation link")
    end

    agent.telegram_send_message(subscription.telegram_chat_id, text, **options)
  rescue TelegramNotifiable::TelegramError => e
    if e.message.include?("blocked") || e.message.include?("chat not found")
      subscription.mark_blocked!
    else
      raise
    end
  end

end
