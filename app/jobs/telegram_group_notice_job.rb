# Said once in the group when its owner allows it (#596): what is copied,
# who can read the copy, and whose allowance the answers spend.
class TelegramGroupNoticeJob < ApplicationJob

  queue_as :default
  retry_on TelegramNotifiable::TelegramError, wait: :polynomially_longer, attempts: 5

  def perform(group)
    return unless group.deliverable?

    agent = group.agent
    text = self.class.text_for(group)
    result = agent.telegram_send_message(group.telegram_chat_id, ERB::Util.html_escape(text))
    sent = result["result"] || {}
    group.telegram_messages.create!(
      role: "assistant",
      text: text,
      sender_name: "souls.house",
      telegram_message_id: sent["message_id"],
      sent_at: sent["date"] ? Time.zone.at(sent["date"]) : Time.current
    )
  end

  def self.text_for(group)
    agent = group.agent
    account = agent.account
    handle = agent.telegram_bot_username.present? ? "@#{agent.telegram_bot_username}" : agent.name
    <<~TEXT.strip
      #{agent.name} can now answer in this group. It only sees messages that mention #{handle} or reply to it.

      Those messages, with your Telegram name, and #{agent.name}'s replies are copied to souls.house, where the people in the account "#{account.name}" can read them. Each answer #{agent.name} gives here uses that account's allowance.
    TEXT
  end

end
