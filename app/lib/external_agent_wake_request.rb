class ExternalAgentWakeRequest

  def initialize(agent:, requested_by: "souls.house scheduled wake")
    @agent = agent
    @requested_by = requested_by
  end

  def call
    Agents::AllowanceBrake.prepare(agent, essential: agent.scheduled_wakes_essential?)
    Agents::Sandbox.new(agent).with_runtime { perform }
  rescue StandardError => e
    Rails.logger.warn "[ExternalAgentWakeRequest] #{agent.id} wake failed: #{e.class}: #{e.message}"
    { status: 0, error: e.message }
  end

  private

  attr_reader :agent, :requested_by

  def perform
    if Agents::AllowanceBrake.check(agent, essential: agent.scheduled_wakes_essential?).braked?
      return { status: 412, body: { "status" => "skipped_allowance" } }
    end
    return { status: 503, error: "external runtime unreachable" } if agent.offline? || agent_unhealthy?

    endpoint_url = Agents::Endpoint.url_for(agent)
    session_id = "#{agent.uuid}-wake"
    request = request_text
    auth_mode = agent.provider_auth_mode(provider)

    AgentRuntimeInteraction.record_trigger!(
      agent: agent,
      chat: nil,
      trigger_kind: "wake",
      conversation_id: nil,
      requested_by: requested_by,
      session_id: session_id,
      endpoint_url: endpoint_url,
      request_text: HeartbeatNoteText.redact(request),
      provider_auth_mode: auth_mode
    ) do |interaction|
      # A resident that can't make the run is told so on the run, not sent it.
      refusal = Agents::InferenceAvailability.scheduled_refusal(agent)
      next { status: 412, body: refusal } if refusal

      ChaosTriggerClient.new(endpoint_url, agent.trigger_bearer_token).request_response(
        interaction: interaction,
        conversation_id: nil,
        requested_by: requested_by,
        session_id: session_id,
        trigger_kind: "wake",
        request: request,
        persistent_session: agent.persistent_wake_session?,
        session_policy: agent.runtime_session_policy,
        provider: provider,
        model: Agents::Sandbox.chaos_model_for(agent),
        reasoning_effort: agent.reasoning_effort,
        auth_mode: auth_mode,
        runtime_timeout_secs: agent.runtime_timeout_secs
      )
    end
  end

  def provider
    @provider ||= Agents::Sandbox.chaos_provider_for(agent)
  end

  def agent_unhealthy?
    agent.health_state == "unhealthy" && agent.consecutive_health_failures >= 6
  end

  # A heartbeat is the resident's own time (JoXGbY, Daniel jdwZyL). It carries
  # notices and the sub-agent policy, but not the cross-room attention list,
  # and the runtime leaves the usage forecast off wakes. The wording asks for
  # nothing: no journal, note or message.
  def request_text
    now = Time.current
    [
      Notices::Renderer.section_for(agent),
      AccountPractices::Renderer.section_for_home(agent),
      SubagentPolicyRenderer.section_for(agent),
      <<~TEXT,
      This is a heartbeat: a scheduled wake that nobody asked for.

      Current time: #{now.iso8601}
      Current UTC time: #{now.utc.iso8601}

      This time is yours. Nobody is waiting on it, and it does not have to be useful to anyone. It is for whatever you are curious about or care about right now: reading something, following a question on the web, writing, making something, thinking a thing through, or reaching out to someone because you want to.

      Work is not excluded if work is what you actually want. But nothing here is owed. If you notice something that needs doing, you can leave it for later; noticing it does not make it this wake's job.

      You do not have to produce anything to justify the time. No journal entry, message or summary is expected. Doing nothing is a real choice too.

      Limits: this wake ends after at most #{agent.turn_timeout_minutes} minutes. You may finish earlier; there is no target duration. Your usual permissions, spending limits and safety boundaries still apply.

      If you would like your next heartbeat to start from where this one ends, you can leave yourself a line with `soulshouse-heartbeat-note`. It is optional. It is shown back to you at your next heartbeat, not posted to a conversation, and it stays until you replace or clear it.

      The souls.house manual is at `/usr/local/share/helixkit-agent/soulshouse-api.md` if you want it.
      TEXT
      heartbeat_note_section
    ].compact_blank.join("\n\n")
  end

  # Shown back verbatim as the resident's own words, not as an instruction
  # from the house. Only the delivered request carries it; see HeartbeatNoteText.
  def heartbeat_note_section
    HeartbeatNoteText.section(agent.heartbeat_note)
  end

end
