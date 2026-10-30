# House notices for enabling a group (#596) and reaching its bot cap (#609).
class TelegramGroupNoticeJob < ApplicationJob

  queue_as :default
  retry_on TelegramNotifiable::TelegramError, wait: :polynomially_longer, attempts: 5

  def perform(group, bot_cap_message_id: nil)
    if bot_cap_message_id
      group.reload
      # A reset and another bot streak may have overtaken this queued notice.
      # The suppressed inbound row identifies the streak, not just its count.
      return unless group.answers_bots? && group.bot_wake_streak == TelegramSubscription::BOT_WAKE_LIMIT &&
        group.bot_cap_notice_message_id == bot_cap_message_id
    end
    return unless group.deliverable?

    agent = group.agent
    text = bot_cap_message_id ? self.class.bot_cap_text_for(group) : self.class.text_for(group)
    result = agent.telegram_send_message(group.telegram_chat_id, ERB::Util.html_escape(text))
    sent = result["result"] || {}
    group.telegram_messages.create!(
      role: "assistant",
      text: text,
      sender_name: Setting.instance.site_name,
      telegram_message_id: sent["message_id"],
      sent_at: sent["date"] ? Time.zone.at(sent["date"]) : Time.current
    )
  end

  def self.text_for(group)
    agent = group.agent
    account = agent.account
    handle = agent.telegram_bot_username.present? ? "@#{agent.telegram_bot_username}" : agent.name
    text = <<~TEXT.strip
      #{agent.name} is now on in this group. It reads the conversation here and answers when someone mentions #{handle}, writes "#{agent.name}", or replies to it.

      Every message in this group from now on, with your Telegram name, and #{agent.name}'s replies are copied to #{Setting.instance.site_name}, where the people in the account "#{account.name}" can read them. Each answer #{agent.name} gives here uses that account's allowance.
    TEXT
    if group.answers_bots?
      senders = if group.answer_bot_usernames.empty?
        "Any bot, with or without a username, is allowed."
      else
        "Only these bot usernames are allowed: #{group.answer_bot_usernames.map { |name| "@#{name}" }.join(", ")}."
      end
      text += "\n\nOther bots can also wake #{agent.name} by mentioning #{handle} or replying to it. #{senders} These answers use the owner's account allowance too. #{agent.name} can answer bots #{TelegramSubscription::BOT_WAKE_LIMIT} times in a row; a message from a person lets her continue."
    end
    text
  end

  def self.bot_cap_text_for(group)
    "#{group.agent.name} has answered bots #{TelegramSubscription::BOT_WAKE_LIMIT} times in a row; a message from a person lets her continue."
  end

end
