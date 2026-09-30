class ResidentTurnCompletion

  def initialize(turn, result)
    @turn, @result = turn, result
  end

  def call
    context = @turn.completion_context
    if context["orientation_snapshot"]
      status = Agents::DailyJournalStatus.new(@turn.agent)
      if status.grown_since?(context["orientation_snapshot"]) && @turn.agent.oriented_at.blank?
        @turn.agent.update!(oriented_at: Time.current)
      end
      if context["orientation_context"] == "birth"
        if @result["status"].between?(200, 299)
          @turn.agent.update!(orientation_completed_at: Time.current)
        else
          @turn.agent.update!(orientation_last_error: "Runtime returned HTTP #{@result['status']}", orientation_last_error_at: Time.current)
        end
      end
    end
    if context["safeguard_detection_id"]
      detection = SafeguardDetection.find_by(id: context["safeguard_detection_id"])
      detection&.update!(cold_offer_outcome: @result["status"] == 200 ? "no_response" : "failed") unless detection&.reclaimed?
    end
    finish_telegram(context) if context["telegram_subscription_id"]
    surface_provider_failure(context)
  end

  private

  def finish_telegram(context)
    subscription = TelegramSubscription.find_by(id: context["telegram_subscription_id"], agent: @turn.agent)
    return unless subscription && @result["status"] == 200
    detection = SafeguardDetection.find_by(id: context["safeguard_roll_id"])
    return unless detection
    body = @result["body"]
    reason = body["session_roll_reason"] || body.dig("telemetry", "session", "roll_reason")
    outcome = body.dig("telemetry", "session", "outcome")
    detection.update!(session_rolled_at: Time.current) if reason == "safeguard-detected" || outcome.in?(%w[fresh rolled fresh_fallback])
    subscription.update!(pending_safeguard_detection: nil) if subscription.pending_safeguard_detection_id == detection.id
  end

  def surface_provider_failure(context)
    interaction = @turn.agent_runtime_interaction
    return unless interaction.provider_auth_mode == "oauth_account"
    body = @result["body"]
    case body["error_kind"]
    when "auth_expired"
      provider = JSON.parse(@turn.payload)["provider"]
      @turn.agent.mark_provider_connection_status!(provider, "expired")
      text = "Provider connection expired. Reconnect it in agent hosting settings."
    when "subscription_limit"
      text = AgentSubscriptionUsage.new(body["subscription_usage"]).user_message
    end
    return unless text
    if interaction.chat
      interaction.chat.messages.create!(role: "assistant", agent: @turn.agent, content: "_#{text}_")
    elsif context["telegram_subscription_id"]
      subscription = TelegramSubscription.find_by(id: context["telegram_subscription_id"], agent: @turn.agent)
      @turn.agent.telegram_send_message(subscription.telegram_chat_id, ERB::Util.html_escape(text)) if subscription
    end
  end

end
