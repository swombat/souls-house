class ProcessTelegramUpdateJob < ApplicationJob

  self.log_arguments = false

  queue_as :default

  def perform(agent, update)
    return process_callback_query(agent, update.fetch("callback_query")) if update["callback_query"]

    message = update.dig("message")
    return unless message
    return if message.dig("chat", "type").present? && message.dig("chat", "type") != "private"

    text = message.dig("text")
    chat_id = message.dig("chat", "id")
    return process_start(agent, message, text, chat_id) if text&.start_with?("/start")
    return process_reset(agent, chat_id) if reset_command?(text)

    content = supported_content(message)
    return unless content

    process_direct_message(agent, message, content, chat_id)
  end

  private

  def process_callback_query(agent, callback_query)
    data = callback_query["data"].to_s
    return unless data.start_with?("safeguard_reset:")

    thread_id = data.delete_prefix("safeguard_reset:")
    chat_id = callback_query.dig("message", "chat", "id")
    subscription = agent.telegram_subscriptions.find_by(id: TelegramSubscription.decode_id(thread_id))
    return unless subscription && subscription.telegram_chat_id == chat_id

    reset_subscription(agent, subscription)
    agent.telegram_answer_callback_query(callback_query["id"], text: "Fresh session requested")
  end

  def process_start(agent, message, text, chat_id)
    deep_link_param = text.split(" ", 2)[1]

    user = verify_deep_link(agent, deep_link_param)
    return send_unknown_user_message(agent, chat_id) unless user

    subscription = agent.telegram_subscriptions.find_or_initialize_by(user: user)
    subscription.update!(
      telegram_chat_id: chat_id,
      telegram_username: message.dig("from", "username"),
      blocked: false
    )

    agent.telegram_send_message(
      chat_id,
      "Connected! You'll receive notifications from <b>#{ERB::Util.html_escape(agent.name)}</b> here."
    )
  end

  def process_reset(agent, chat_id)
    subscription = agent.telegram_subscriptions.find_by(telegram_chat_id: chat_id)
    return unless subscription

    reset_subscription(agent, subscription)
  end

  def reset_subscription(agent, subscription)
    subscription.request_runtime_reset!
    text = "souls.house will start a fresh session for #{agent.name} in this conversation. Your visible conversation and #{agent.name}'s memory are not deleted. Your next message begins the fresh session."
    result = agent.telegram_send_message(subscription.telegram_chat_id, ERB::Util.html_escape(text))
    telegram_message = result["result"] || {}
    subscription.telegram_messages.create!(
      role: "assistant",
      text: text,
      sender_name: "souls.house",
      telegram_message_id: telegram_message["message_id"],
      sent_at: telegram_message["date"] ? Time.zone.at(telegram_message["date"]) : Time.current
    )
  end

  def reset_command?(text)
    text.to_s.match?(/\A\/reset(?:@\w+)?\s*\z/i)
  end

  def process_direct_message(agent, message, content, chat_id)
    subscription = agent.telegram_subscriptions.find_by(telegram_chat_id: chat_id)
    return unless subscription

    subscription.update!(
      telegram_username: message.dig("from", "username"),
      blocked: false
    )

    telegram_message = create_inbound_message(subscription, message, content)
    return unless telegram_message

    if content[:media_kind]
      if content[:file_size].to_i > TelegramMessage.media_limit_for(content[:media_kind])
        fail_oversized_media(agent, subscription, telegram_message)
      else
        PrepareTelegramMediaJob.perform_later(telegram_message, content[:file_id], content[:telegram_metadata])
      end
    elsif agent.active? && !agent.paused? && agent.external? && agent.trigger_bearer_token.present?
      TelegramAgentTriggerJob.perform_later(subscription, telegram_message)
    end
  end

  def create_inbound_message(subscription, message, content)
    telegram_message_id = message["message_id"]
    existing = subscription.telegram_messages.find_by(telegram_message_id: telegram_message_id) if telegram_message_id
    return if existing

    subscription.telegram_messages.create!(
      role: "user",
      text: content[:text],
      caption: content[:caption],
      media_kind: content[:media_kind],
      media_status: content[:media_kind] ? "pending" : nil,
      media_metadata: content[:telegram_metadata] || {},
      sender_name: subscription.subscriber_name,
      sender_username: message.dig("from", "username"),
      telegram_message_id: telegram_message_id,
      sent_at: message["date"] ? Time.zone.at(message["date"]) : Time.current
    )
  rescue ActiveRecord::RecordNotUnique
    nil
  end

  def supported_content(message)
    return { text: message["text"] } if message["text"].present?

    if message["photo"].present?
      photo = message["photo"].max_by { |entry| entry["width"].to_i * entry["height"].to_i }
      return media_content("photo", message, photo, width: photo["width"], height: photo["height"])
    end

    return media_content("voice", message, message["voice"], duration: message.dig("voice", "duration")) if message["voice"].present?
    media_content(
      "video",
      message,
      message["video"],
      duration: message.dig("video", "duration"),
      width: message.dig("video", "width"),
      height: message.dig("video", "height")
    ) if message["video"].present?
  end

  def media_content(kind, message, media, metadata = {})
    caption = message["caption"].presence
    label = { "photo" => "Photo", "voice" => "Voice message", "video" => "Video" }.fetch(kind)
    text = [ caption, "[#{label} — processing]" ].compact.join("\n\n")

    {
      text: text,
      caption: caption,
      media_kind: kind,
      file_id: media["file_id"],
      file_size: media["file_size"],
      telegram_metadata: metadata.compact
    }
  end

  def fail_oversized_media(agent, subscription, telegram_message)
    telegram_message.update!(
      media_status: "failed",
      media_error: "too_large"
    )
    telegram_message.rebuild_text!
    agent.telegram_send_message(subscription.telegram_chat_id, oversized_message(telegram_message.media_kind))
  end

  def oversized_message(kind)
    if kind == "video"
      "That video is over souls.house's 20 MB Telegram limit. Please trim or compress it and send it again."
    else
      "That #{kind} is over souls.house's 20 MB Telegram limit. Please send a smaller file."
    end
  end

  def verify_deep_link(agent, param)
    return nil unless param.present?

    data = Rails.cache.read("telegram_deep_link:#{param}")
    return nil unless data && data[:agent_id] == agent.id

    agent.account.users.find_by(id: data[:user_id])
  end

  def send_unknown_user_message(agent, chat_id)
    agent.telegram_send_message(
      chat_id,
      "I couldn't identify your account. Please use the registration link from the app."
    )
  end

end
