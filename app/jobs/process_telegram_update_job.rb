class ProcessTelegramUpdateJob < ApplicationJob

  self.log_arguments = false

  queue_as :default

  def perform(agent, update)
    return process_callback_query(agent, update.fetch("callback_query")) if update["callback_query"]
    return process_membership(agent, update.fetch("my_chat_member")) if update["my_chat_member"]

    message = update.dig("message")
    return unless message
    chat_type = message.dig("chat", "type")
    return process_group_message(agent, message) if TelegramSubscription::GROUP_CHAT_TYPES.include?(chat_type)
    return if chat_type.present? && chat_type != "private"

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
    subscription = TelegramSubscription.where(agent: agent).find_by(id: TelegramSubscription.decode_id(thread_id))
    return unless subscription && subscription.telegram_chat_id == chat_id
    return if subscription.group? && !subscription.deliverable?

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
      "Connected! You can message <b>#{ERB::Util.html_escape(agent.name)}</b> directly here."
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

    enqueue_wake(agent, subscription, telegram_message, content)
  end

  # Groups (#596). The bot hears about a group the first time it is added
  # (my_chat_member) or the first time a message from it arrives, and records
  # it switched off. Nothing from a group is kept while it is off.
  #
  # A group switches on the first time an owner of the resident's account,
  # whose Telegram is linked to this bot, addresses the bot there; or when an
  # owner switches it on in settings. Once on, every message is kept as
  # context, and only one addressed to the bot (an @mention of its username,
  # a text_mention of it, a reply to one of its own messages, or, in a group
  # that is already on, a person writing the resident's name) wakes the
  # resident, which then sees the conversation above the mention too.
  def process_membership(agent, member_update)
    chat = member_update["chat"] || {}
    return unless TelegramSubscription::GROUP_CHAT_TYPES.include?(chat["type"])

    group = record_group(agent, chat)
    status = member_update.dig("new_chat_member", "status")
    if %w[left kicked].include?(status)
      # A bot added back later starts again: off until an owner addresses it.
      group.update!(removed_at: Time.current, allowed: false, allowed_at: nil, allowed_by: nil)
    elsif group.removed_at
      group.update!(removed_at: nil)
    end
    RefreshTelegramBotInfoJob.perform_later(agent)
  end

  def process_group_message(agent, message)
    return migrate_group(agent, message) if message["migrate_to_chat_id"]

    group = record_group(agent, message["chat"])
    from_person = !message.dig("from", "is_bot")
    addressed = from_person && addressed_to_bot?(agent, message)
    allow_on_first_owner_address(agent, group, message) if addressed
    return unless group.deliverable?

    # Pepe, 29 Oct (eqRmyj): "Alanis?" should reach her like the tag does.
    # Only a person's words count, never another bot's (that loop is #609's),
    # and only once the group is on: a name alone never switches a group on.
    addressed ||= from_person && names_resident?(agent, message)

    content = supported_content(message)
    return unless content

    telegram_message = create_inbound_message(group, message, content, addressed: addressed)
    return unless telegram_message

    if addressed
      enqueue_wake(agent, group, telegram_message, content)
    elsif content[:media_kind]
      prepare_context_media(group, telegram_message, content)
    end
  end

  # The owner's first word to the bot in a group is their consent to it
  # being there. Only the first: a group an owner later switched off in
  # settings stays off until it is switched on there again.
  def allow_on_first_owner_address(agent, group, message)
    return if group.allowed? || group.allowed_at || group.removed_at

    owner = linked_owner(agent, message.dig("from", "id"))
    return unless owner

    allowed = group.with_lock do
      next false if group.allowed? || group.allowed_at || group.removed_at

      group.allow!(by: owner)
      true
    end
    TelegramGroupNoticeJob.perform_later(group) if allowed
  end

  # A direct chat's id is the person's Telegram user id, so the owner is
  # whoever linked their Telegram to this bot and owns the account.
  def linked_owner(agent, telegram_user_id)
    return if telegram_user_id.blank?

    agent.telegram_subscriptions.where(telegram_chat_id: telegram_user_id).includes(:user)
      .map(&:user).find { |user| agent.account.owned_by?(user) }
  end

  # Media nobody addressed is prepared the same way, so the resident can see
  # it when someone later asks about it, but it wakes nobody and is never
  # answered with an error in the group.
  def prepare_context_media(group, telegram_message, content)
    if content[:file_size].to_i > TelegramMessage.media_limit_for(content[:media_kind])
      telegram_message.update!(media_status: "failed", media_error: "too_large")
      telegram_message.rebuild_text!
    else
      PrepareTelegramMediaJob.perform_later(telegram_message, content[:file_id], content[:telegram_metadata])
    end
  end

  def record_group(agent, chat)
    group = agent.telegram_groups.find_or_create_by!(telegram_chat_id: chat["id"]) do |record|
      record.title = chat["title"]
    end
    group.update!(title: chat["title"]) if chat["title"].present? && group.title != chat["title"]
    group
  rescue ActiveRecord::RecordNotUnique
    agent.telegram_groups.find_by!(telegram_chat_id: chat["id"])
  end

  # A group upgraded to a supergroup gets a new chat id. Keep the record (and
  # its allowance) on the new id unless the new id already has one.
  def migrate_group(agent, message)
    group = agent.telegram_groups.find_by(telegram_chat_id: message.dig("chat", "id"))
    return unless group
    return if agent.telegram_groups.exists?(telegram_chat_id: message["migrate_to_chat_id"])

    group.update!(telegram_chat_id: message["migrate_to_chat_id"])
  end

  def addressed_to_bot?(agent, message)
    bot_id = agent.telegram_bot_user_id
    return true if bot_id && message.dig("reply_to_message", "from", "id") == bot_id

    text = message["text"] || message["caption"]
    entities = message["entities"] || message["caption_entities"] || []
    handle = "@#{agent.telegram_bot_username}".downcase
    entities.any? do |entity|
      case entity["type"]
      when "mention" then entity_text(text, entity)&.downcase == handle
      when "text_mention" then bot_id.present? && entity.dig("user", "id") == bot_id
      else false
      end
    end
  end

  # The resident's name as a whole word, in any case: "Alanis?" and "ask
  # alanis" wake her; "Alanisa" does not. Names under three characters are
  # too likely to be ordinary words to count.
  def names_resident?(agent, message)
    name = agent.name.to_s.strip
    return false if name.length < 3

    text = message["text"] || message["caption"]
    return false if text.blank?

    text.match?(/(?<![\p{L}\p{N}_])#{Regexp.escape(name)}(?![\p{L}\p{N}_])/i)
  end

  # Telegram measures entity offsets in UTF-16 code units.
  def entity_text(text, entity)
    return if text.blank?

    units = text.encode("UTF-16LE")
    units.byteslice(entity["offset"].to_i * 2, entity["length"].to_i * 2)&.force_encoding("UTF-16LE")&.encode("UTF-8")
  rescue EncodingError
    nil
  end

  def enqueue_wake(agent, subscription, telegram_message, content)
    if content[:media_kind]
      if content[:file_size].to_i > TelegramMessage.media_limit_for(content[:media_kind])
        fail_oversized_media(agent, subscription, telegram_message)
      else
        PrepareTelegramMediaJob.perform_later(telegram_message, content[:file_id], content[:telegram_metadata])
      end
    elsif agent.active? && !agent.paused? && !agent.billing_held? && agent.external? && agent.trigger_bearer_token.present?
      TelegramAgentTriggerJob.perform_later(subscription, telegram_message)
    end
  end

  def create_inbound_message(subscription, message, content, addressed: true)
    telegram_message_id = message["message_id"]
    existing = subscription.telegram_messages.find_by(telegram_message_id: telegram_message_id) if telegram_message_id
    return if existing

    subscription.telegram_messages.create!(
      **sender_attributes(subscription, message),
      role: "user",
      addressed: addressed,
      text: content[:text],
      caption: content[:caption],
      media_kind: content[:media_kind],
      media_status: content[:media_kind] ? "pending" : nil,
      media_metadata: content[:telegram_metadata] || {},
      sender_username: message.dig("from", "username"),
      telegram_message_id: telegram_message_id,
      sent_at: message["date"] ? Time.zone.at(message["date"]) : Time.current
    )
  rescue ActiveRecord::RecordNotUnique
    nil
  end

  # In a DM the sender is the subscriber. In a group the sender is whoever
  # wrote, named as Telegram names them: never the owner, whoever the owner is.
  def sender_attributes(subscription, message)
    return { sender_name: subscription.subscriber_name } if subscription.direct?

    from = message["from"] || {}
    name = [ from["first_name"], from["last_name"] ].compact_blank.join(" ").presence ||
      from["username"].presence || "Telegram user"
    {
      sender_name: name,
      sender_telegram_user_id: from["id"],
      reply_to_telegram_message_id: message.dig("reply_to_message", "message_id")
    }
  end

  def supported_content(message)
    return { text: message["text"] } if message["text"].present?

    if message["photo"].present?
      photo = message["photo"].max_by { |entry| entry["width"].to_i * entry["height"].to_i }
      return media_content("photo", message, photo, width: photo["width"], height: photo["height"])
    end

    return media_content("voice", message, message["voice"], duration: message.dig("voice", "duration")) if message["voice"].present?

    if message["video_note"].present?
      length = message.dig("video_note", "length")
      return media_content(
        "video",
        message,
        message["video_note"],
        duration: message.dig("video_note", "duration"),
        width: length,
        height: length
      )
    end

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
