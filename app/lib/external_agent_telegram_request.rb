class ExternalAgentTelegramRequest

  TRANSCRIPT_WINDOW = 30

  def initialize(agent:, subscription:, telegram_message:)
    @agent = agent
    @subscription = subscription
    @telegram_message = telegram_message
  end

  def call
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
      last_included_message_id: telegram_message.id,
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
    result
  rescue StandardError => e
    Rails.logger.warn "[ExternalAgentTelegramRequest] #{agent.id} trigger failed: #{e.class}: #{e.message}"
    { status: 0, error: e.message }
  end

  private

  attr_reader :agent, :subscription, :telegram_message

  def provider
    @provider ||= Agents::Sandbox.chaos_provider_for(agent)
  end

  def trigger_payload
    payload = {
      channel: "telegram",
      sender: {
        name: subscription.subscriber_name,
        email: subscription.user.email_address,
        telegram_username: subscription.telegram_username
      },
      text: telegram_message.text,
      thread_id: subscription.to_param,
      history_cursor: telegram_message.to_param,
      runtime_session_generation: subscription.runtime_session_generation
    }
    payload[:roll_session] = true if pending_safeguard_detection
    payload[:media] = telegram_message.media_json if telegram_message.media?
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
      History cursor: #{telegram_message.to_param}
      Sender: #{subscription.subscriber_name} <#{subscription.user.email_address}>
      Telegram username: #{subscription.telegram_username.presence || "_unknown_"}
      Message:
      #{telegram_message.media_prompt}

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
      New Telegram DM from #{subscription.subscriber_name} (thread #{subscription.to_param}):
      #{telegram_message.media_prompt}

      Reply by piping stdin to `helixkit-send-telegram --reply-to #{subscription.to_param}` if appropriate. Stdout is diagnostic only.
      History cursor: #{telegram_message.to_param}
      TEXT
    ].compact_blank.join("\n\n")
  end

  def transcript_text
    subscription.telegram_messages.chronological.last(TRANSCRIPT_WINDOW).map do |message|
      message.transcript_line
    end.join("\n")
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
