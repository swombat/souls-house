class AgentAttentionFeed

  CHANNELS = %i[helixkit telegram].freeze
  AUTHOR_TYPES = %i[human resident unknown].freeze
  PREVIEW_LENGTH = 240

  def initialize(agent)
    @agent = agent
  end

  def call
    checked = {}
    items = CHANNELS.flat_map do |channel|
      collect(channel, checked)
    end

    items.sort_by! { |item| [ item[:sort_at], item[:channel], item[:thread_id] ] }
    items.reverse!
    items.each { |item| item.delete(:sort_at) }

    {
      generated_at: Time.current.iso8601,
      checked: checked,
      counts: counts_for(items),
      items: items
    }
  end

  private

  attr_reader :agent

  def collect(channel, checked)
    send("#{channel}_items").tap { checked[channel] = "ok" }
  rescue StandardError => e
    checked[channel] = "failed"
    Rails.logger.warn "[AgentAttentionFeed] agent=#{agent.id} channel=#{channel} failed: #{e.class}: #{e.message}"
    []
  end

  def helixkit_items
    latest_messages = Message.kept
      .where(id: latest_helixkit_message_ids)
      .where("messages.agent_id IS NULL OR messages.agent_id != ?", agent.id)
      .includes(:chat, :agent, user: :profile)
      .to_a
    messages_with_attachments = ActiveStorage::Attachment
      .where(record_type: "Message", record_id: latest_messages.map(&:id), name: "attachments")
      .distinct
      .pluck(:record_id)
      .index_with(true)

    latest_messages.map do |message|
      {
        channel: "helixkit",
        thread_id: message.chat.to_param,
        title: message.chat.title_or_default,
        reachable: true,
        latest_message: {
          id: message.to_param,
          authored_at: message.created_at.iso8601,
          author_type: helixkit_author_type(message),
          author_name: helixkit_author_name(message),
          preview: preview(message.content, attachment: messages_with_attachments.key?(message.id))
        },
        detail_path: Rails.application.routes.url_helpers.api_v1_conversation_path(message.chat),
        sort_at: message.created_at
      }
    end
  end

  # The latest turn is taken over every message, discarded or not, so removing
  # an answer can't resurface the question before it as unanswered. A room
  # whose latest turn was discarded simply has nothing to show.
  def latest_helixkit_message_ids
    Message
      .where(chat_id: agent.chats.kept.active.select(:id), role: %w[user assistant])
      .select("DISTINCT ON (messages.chat_id) messages.id")
      .reorder("messages.chat_id, messages.created_at DESC, messages.id DESC")
  end

  def telegram_items
    TelegramMessage
      .where(id: latest_telegram_message_ids, role: "user")
      .includes(telegram_subscription: { user: :profile })
      .map do |message|
        subscription = message.telegram_subscription
        subscriber_name = telegram_subscriber_name(subscription)
        {
          channel: "telegram",
          thread_id: subscription.to_param,
          title: subscriber_name,
          reachable: !subscription.blocked?,
          latest_message: {
            id: message.to_param,
            authored_at: message.sent_at.iso8601,
            author_type: "human",
            author_name: message.sender_name.presence || subscriber_name,
            preview: preview(message.text)
          },
          detail_path: Rails.application.routes.url_helpers.api_v1_telegram_conversation_path(subscription),
          sort_at: message.sent_at
        }
      end
  end

  def latest_telegram_message_ids
    TelegramMessage
      .where(telegram_subscription_id: agent.telegram_subscriptions.select(:id))
      .select("DISTINCT ON (telegram_messages.telegram_subscription_id) telegram_messages.id")
      .reorder("telegram_messages.telegram_subscription_id, telegram_messages.sent_at DESC, telegram_messages.id DESC")
  end

  def helixkit_author_type(message)
    return "human" if message.user_id.present?
    return "resident" if message.agent_id.present?

    "unknown"
  end

  def helixkit_author_name(message)
    return message.user.full_name.presence || message.user.email_address.split("@").first if message.user
    return message.agent.name if message.agent

    "Unknown"
  end

  def telegram_subscriber_name(subscription)
    subscription.user.full_name.presence || subscription.user.email_address.split("@").first
  end

  def preview(content, attachment: false)
    text = content.to_s.squish
    return "[attachment]" if text.blank? && attachment

    text.truncate(PREVIEW_LENGTH, omission: "…")
  end

  def counts_for(items)
    by_author_type = AUTHOR_TYPES.index_with { 0 }
    items.each { |item| by_author_type[item.dig(:latest_message, :author_type).to_sym] += 1 }

    {
      total: items.size,
      helixkit: items.count { |item| item[:channel] == "helixkit" },
      telegram: items.count { |item| item[:channel] == "telegram" },
      by_author_type: by_author_type
    }
  end

end
