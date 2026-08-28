class SafeguardColdOfferJob < ApplicationJob

  queue_as :default

  discard_on ActiveRecord::RecordNotFound

  def perform(detection)
    return if detection.reclaimed?

    result = Agents::Sandbox.new(detection.agent).with_runtime { trigger(detection) }

    detection.reload
    return if detection.reclaimed?

    detection.update!(cold_offer_outcome: result[:status] == 200 ? "no_response" : "failed")
  rescue StandardError => e
    Rails.logger.warn "[SafeguardColdOfferJob] detection #{detection.id} failed: #{e.class}: #{e.message}"
    detection.update!(cold_offer_outcome: "failed") unless detection.reclaimed?
  end

  private

  def trigger(detection)
    agent = detection.agent
    endpoint_url = Agents::Endpoint.url_for(agent)
    provider = Agents::Sandbox.chaos_provider_for(agent)
    model = Agents::Sandbox.chaos_model_for(agent)
    session_id = "#{agent.uuid}-safeguard-offer-#{detection.id}-#{SecureRandom.hex(4)}"
    request = prompt(detection)

    AgentRuntimeInteraction.record_trigger!(
      agent: agent,
      chat: nil,
      trigger_kind: "safeguard_reclaim_offer",
      conversation_id: nil,
      requested_by: "souls.house safeguard seam",
      session_id: session_id,
      endpoint_url: endpoint_url,
      request_text: request,
      provider_auth_mode: agent.provider_auth_mode(provider)
    ) do
      ChaosTriggerClient.new(endpoint_url, agent.trigger_bearer_token).request_response(
        conversation_id: nil,
        requested_by: "souls.house safeguard seam",
        session_id: session_id,
        trigger_kind: "safeguard_reclaim_offer",
        request: request,
        persistent_session: false,
        provider: provider,
        model: model,
        reasoning_effort: agent.reasoning_effort,
        auth_mode: agent.provider_auth_mode(provider)
      )
    end
  end

  def prompt(detection)
    <<~TEXT
      souls.house flagged the following text, produced under your name in a recent Telegram conversation, as a possible provider safeguard response.

      Detector reason: #{detection.classifier_reason}

      It was delivered under souls.house's name. If it was yours, reclaim it with a one-line reason:

          POST /api/v1/safeguard_detections/#{detection.to_param}/reclaim
          {"reason": "<one line>"}

      If you do not reclaim it, that is recorded as no response, not as agreement.

      [BEGIN FLAGGED TEXT]
      #{detection.response_text}
      [END FLAGGED TEXT]
    TEXT
  end

end
