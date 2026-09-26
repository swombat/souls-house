class ExternalAgentWakeRequest

  def initialize(agent:, requested_by: "HelixKit scheduled wake")
    @agent = agent
    @requested_by = requested_by
  end

  def call
    Agents::Sandbox.new(agent).with_runtime { perform }
  rescue StandardError => e
    Rails.logger.warn "[ExternalAgentWakeRequest] #{agent.id} wake failed: #{e.class}: #{e.message}"
    { status: 0, error: e.message }
  end

  private

  attr_reader :agent, :requested_by

  def perform
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
      request_text: request,
      provider_auth_mode: auth_mode
    ) do
      ChaosTriggerClient.new(endpoint_url, agent.trigger_bearer_token).request_response(
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
        auth_mode: auth_mode
      )
    end
  end

  def provider
    @provider ||= Agents::Sandbox.chaos_provider_for(agent)
  end

  def agent_unhealthy?
    agent.health_state == "unhealthy" && agent.consecutive_health_failures >= 6
  end

  def request_text
    now = Time.current
    [
      Notices::Renderer.section_for(agent),
      AgentAttentionRenderer.section_for(agent),
      <<~TEXT
      HelixKit is inviting you to wake for a scheduled self-directed session.

      Current time: #{now.iso8601}
      Current UTC time: #{now.utc.iso8601}
      Requested by: #{requested_by}.

      This is an invitation, not a command. You may choose to do nothing.

      If you want to act, choose your own appropriate work for this wake session. Examples:

      - Read HelixKit conversations or whiteboards through the current runtime-owned manual at `/usr/local/share/helixkit-agent/helixkit-api.md` and post to HelixKit if you have something useful, timely, and non-noisy to say.
      - Examine your repository folders, identity, journals, or memory files and do small tidying or self-maintenance.
      - Improve your own scaffolding in a bounded, reviewable way.
      - Do something else you freely choose within your available tools, shell, and network access, if it is genuinely worthwhile.

      Freedom and budget:

      - Enjoy the room to explore, use bash, curl, git, and local files, and follow your own judgment.
      - Keep it reasonable. Prefer a small number of purposeful reads or commands over broad web crawls, huge downloads, or open-ended wandering.
      - Do not consume lots of tokens, bandwidth, API calls, or money unless there is a clear reason.
      - If curiosity opens a large path, leave yourself a note or plan rather than trying to exhaust it in this wake.

      Repository stewardship:

      - Prefer small, clear changes.
      - If you commit changes, write a very clear commit message explaining what changed and why so Daniel can review it on GitHub.
      - Treat identity/soul.md as protected defining identity. Do not change it without explicit Daniel review/approval; the runtime also has a Git pre-commit guard for this.

      If there is no useful action to take, simply finish without posting or changing files.
      TEXT
    ].compact_blank.join("\n\n")
  end

end
