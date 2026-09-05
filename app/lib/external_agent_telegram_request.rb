class ExternalAgentTelegramRequest

  TRANSCRIPT_WINDOW = 30

  def initialize(agent:, subscription:, telegram_message:)
    @agent = agent
    @subscription = subscription
    @telegram_message = telegram_message
  end

  def call
    agent.reload.require_conversation_runtime!
    return { status: 204, skipped: true } if telegram_messages.empty?
    return { status: 503, error: "external runtime unreachable" } if agent.offline?

    endpoint_url = Agents::Endpoint.url_for(agent)
    request = request_text
    auth_mode = agent.provider_auth_mode(provider)

    result = AgentRuntimeInteraction.record_trigger!(
      agent: agent,
      chat: nil,
      trigger_kind: "telegram",
      conversation_id: subscription.to_param,
      requested_by: subscription.user.email_address,
      session_id: "#{agent.uuid}-telegram-#{subscription.id}",
      endpoint_url: endpoint_url,
      request_text: request,
      last_included_message_id: last_message.id,
      provider_auth_mode: auth_mode
    ) do
      ChaosTriggerClient.new(endpoint_url, agent.trigger_bearer_token).request_response(
        conversation_id: subscription.to_param,
        requested_by: subscription.user.email_address,
        session_id: "#{agent.uuid}-telegram-#{subscription.id}",
        trigger_kind: "telegram",
        request: request,
        request_delta: pending_safeguard_detection ? nil : request_delta_text,
        persistent_session: agent.persistent_session?,
        provider: provider,
        model: Agents::Sandbox.chaos_model_for(agent),
        reasoning_effort: agent.reasoning_effort,
        auth_mode: auth_mode,
        trigger_payload: trigger_payload
      )
    end
    acknowledge_safeguard_roll!(result)
    surface_runtime_failure!(result) if auth_mode == "oauth_account"
    result
  rescue Agent::RuntimeAvailability::Unavailable => e
    { status: 409, error: e.code, skipped: true }
  rescue StandardError => e
    Rails.logger.warn "[ExternalAgentTelegramRequest] #{agent.id} trigger failed: #{e.class}: #{e.message}"
    { status: 0, error: e.message }
  end

  private

  attr_reader :agent, :subscription, :telegram_message

  def provider
    @provider ||= Agents::Sandbox.chaos_provider_for(agent)
  end

  def surface_runtime_failure!(result)
    case result.dig(:body, "error_kind")
    when "auth_expired"
      agent.mark_provider_connection_status!(provider, "expired")
      send_notice("Provider connection expired. Reconnect it in agent hosting settings.")
    when "subscription_limit"
      usage = AgentSubscriptionUsage.new(result.dig(:body, "subscription_usage"))
      send_notice(usage.user_message(time_zone: subscription.user.timezone))
    end
  end

  def send_notice(text)
    agent.telegram_send_message(subscription.telegram_chat_id, ERB::Util.html_escape(text))
  end

  def trigger_payload
    payload = {
      channel: "telegram",
      sender: {
        name: subscription.subscriber_name,
        email: subscription.user.email_address,
        telegram_username: subscription.telegram_username
      },
      text: telegram_messages.map(&:text).join("\n\n"),
      messages: telegram_messages.map(&:transcript_json),
      thread_id: subscription.to_param,
      history_cursor: last_message.to_param,
      runtime_session_generation: subscription.runtime_session_generation
    }
    payload[:roll_session] = true if pending_safeguard_detection
    payload[:media] = last_message.media_json if telegram_messages.one? && last_message.media?
    payload
  end

  def request_text
    [
      Notices::Renderer.section_for(agent),
      safeguard_notice,
      <<~TEXT
      souls.house received a Telegram direct message for you.

      Channel: telegram
      Thread ID: #{subscription.to_param}
      History cursor: #{last_message.to_param}
      Sender: #{subscription.subscriber_name} <#{subscription.user.email_address}>
      Telegram username: #{subscription.telegram_username.presence || "_unknown_"}
      New messages (#{telegram_messages.size}, oldest first):
      #{messages_prompt}

      Telegram is a direct, push-to-phone channel. Decide whether and how to reply in that register.
      Your final Chaos stdout is diagnostic only. To reply, prefer piping the message through stdin:

          printf '%s\n' 'your reply' | helixkit-send-telegram --reply-to #{subscription.to_param}

      You can verify the ground-truth bytes at GET /api/v1/telegram_conversations/#{subscription.to_param}.

      RECENT TELEGRAM TRANSCRIPT FROM DATABASE:
      #{transcript_text}
      TEXT
    ].compact_blank.join("\n\n")
  end

  def request_delta_text
    [
      Notices::Renderer.section_for(agent),
      <<~TEXT
      New Telegram DMs from #{subscription.subscriber_name} (thread #{subscription.to_param}), oldest first:
      #{messages_prompt}

      Reply by piping stdin to `helixkit-send-telegram --reply-to #{subscription.to_param}` if appropriate. Stdout is diagnostic only.
      History cursor: #{last_message.to_param}
      TEXT
    ].compact_blank.join("\n\n")
  end

  def transcript_text
    subscription.telegram_messages
      .where("id <= ?", last_message.id)
      .chronological
      .last(TRANSCRIPT_WINDOW)
      .map do |message|
      message.transcript_line
    end.join("\n")
  end

  def messages_prompt
    telegram_messages.map do |message|
      <<~TEXT.strip
      [#{message.sent_at.iso8601} · cursor #{message.to_param}]
      #{message.media_prompt}
      TEXT
    end.join("\n\n")
  end

  def telegram_messages
    return @telegram_messages if defined?(@telegram_messages)

    messages = subscription.telegram_messages
      .where(role: "user")
      .where("id > ?", message_cursor)
      .order(:id)
      .to_a

    # A media preparation job will enqueue another wake when it reaches ready
    # or failed. Keep later text behind it so the resident sees the conversation
    # in the same order as the sender.
    @telegram_messages = messages.take_while { |message| message.media_status != "pending" }
  end

  def message_cursor
    return prior_cursor_message_id if prior_cursor_message_id

    earlier_media_id = subscription.telegram_messages
      .where(role: "user")
      .where.not(media_kind: nil)
      .where("id < ?", telegram_message.id)
      .minimum(:id)

    [ telegram_message.id, earlier_media_id ].compact.min - 1
  end

  def last_message
    telegram_messages.last
  end

  # Failed and busy attempts must not advance the cursor. A later queued job
  # should retry every message that the resident has not successfully received.
  def prior_cursor_message_id
    return @prior_cursor_message_id if defined?(@prior_cursor_message_id)

    @prior_cursor_message_id = AgentRuntimeInteraction
      .where(
        agent: agent,
        trigger_kind: "telegram",
        conversation_obfuscated_id: subscription.to_param
      )
      .where.not(last_included_message_id: nil)
      .where(transport_status: 200...300, runtime_status: "ok")
      .maximum(:last_included_message_id)
  end

  def pending_safeguard_detection
    return @pending_safeguard_detection if defined?(@pending_safeguard_detection)

    @pending_safeguard_detection = subscription.pending_safeguard_detection
  end

  def safeguard_notice
    SafeguardNoticeRenderer.for_resident(pending_safeguard_detection) if pending_safeguard_detection
  end

  def acknowledge_safeguard_roll!(result)
    detection = pending_safeguard_detection
    return unless detection && result[:status] == 200

    body = result[:body].to_h
    roll_reason = body["session_roll_reason"] || body.dig("telemetry", "session", "roll_reason")
    session_outcome = body.dig("telemetry", "session", "outcome")

    if roll_reason == "safeguard-detected" || session_outcome.in?(%w[fresh rolled fresh_fallback])
      detection.update!(session_rolled_at: Time.current)
    end
    subscription.update!(pending_safeguard_detection: nil)
  end

end
