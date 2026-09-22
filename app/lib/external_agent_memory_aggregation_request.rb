class ExternalAgentMemoryAggregationRequest

  AGGREGATION_TIMEOUT_SECS = 30.minutes.to_i
  PERIODS = %w[daily weekly monthly].freeze

  def initialize(agent:, period:, target:, requested_by: "HelixKit memory aggregation")
    @agent = agent
    @period = period.to_s
    @target = target.to_s
    @requested_by = requested_by
  end

  def call
    Agents::Sandbox.new(agent).with_runtime { perform }
  rescue StandardError => e
    Rails.logger.warn "[ExternalAgentMemoryAggregationRequest] #{agent.id} #{period}/#{target} failed: #{e.class}: #{e.message}"
    { status: 0, error: e.message }
  end

  private

  attr_reader :agent, :period, :target, :requested_by

  def perform
    return { status: 503, error: "external runtime unreachable" } if agent.offline? || agent_unhealthy?
    raise ArgumentError, "period must be one of #{PERIODS.to_sentence}" unless PERIODS.include?(period)
    raise ArgumentError, "target is required" if target.blank?

    endpoint_url = Agents::Endpoint.url_for(agent)
    session_id = "#{agent.uuid}-memory-#{period}-#{target}"
    request = request_text
    auth_mode = agent.provider_auth_mode(provider)

    AgentRuntimeInteraction.record_trigger!(
      agent: agent,
      chat: nil,
      trigger_kind: "memory_aggregation_#{period}",
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
        trigger_kind: "memory_aggregation_#{period}",
        trigger_payload: { memory_aggregation: { period: period, target: target, notices: Notices::Renderer.section_for(agent) } },
        request: request,
        provider: provider,
        model: Agents::Sandbox.chaos_model_for(agent),
        reasoning_effort: agent.reasoning_effort,
        auth_mode: auth_mode,
        read_timeout: AGGREGATION_TIMEOUT_SECS + 30,
        runtime_timeout_secs: AGGREGATION_TIMEOUT_SECS
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
    [
      Notices::Renderer.section_for(agent),
      <<~TEXT
      HelixKit is inviting you to run a #{period} memory aggregation for #{target}.

      This is a scaffolded continuity invitation, not a Rails-authored summary task. Wake as yourself, with your own identity and judgment. Read the relevant journal and aggregation files from your hosted filesystem, then decide what, if anything, should be integrated.

      Suggested source locations:

      - Daily journals: `~/identity/memory/daily-journals/`
      - Weekly journals: `~/identity/memory/weekly-journals/`
      - Monthly journals: `~/identity/memory/monthly-journals/`
      - Yearly journals: `~/identity/memory/yearly-journals/`
      - Self-narrative: `~/identity/self-narrative.md`

      Suggested output for this run:

      #{output_path_bullet}

      Pattern:

      - Read only what is relevant for this #{period} aggregation.
      - Create the target memory directory if it does not exist yet.
      - Preserve uncertainty. Do not force richness, meaning, or drama where there is none.
      - Write in your own voice, as narrative integration rather than a mechanical digest.
      - If the period has no real shape, it is valid to write a very small aggregation or explicitly record that there was no durable shape.
      - Make the output idempotent: if this aggregation already exists, revise or replace it carefully rather than duplicating it.
      - Gently consider whether `~/identity/self-narrative.md` wants a small update. Only change it if something feels durable enough to belong there; no self-narrative change is often the right answer.
      - Treat `~/identity/soul.md` as protected defining identity. Do not edit it.

      When finished, say briefly on stdout what you changed, including whether the aggregation file changed and whether self-narrative changed.
      TEXT
    ].compact_blank.join("\n\n")
  end

  def output_path_bullet
    case period
    when "daily"
      "- Append one entry for #{target} to `~/identity/memory/weekly-journals/#{week_monday_for(target)}.md`"
    when "weekly"
      "- Append one entry for the week of #{target} to `~/identity/memory/monthly-journals/#{month_for(target)}.md`"
    when "monthly"
      "- Append one entry for #{target} to `~/identity/memory/yearly-journals/#{year_for_month(target)}.md`"
    end
  end

  def week_monday_for(date_string)
    Date.parse(date_string).beginning_of_week.iso8601
  rescue ArgumentError
    "{week-Monday-for-#{date_string}}"
  end

  def month_for(date_string)
    Date.parse(date_string).strftime("%Y-%m")
  rescue ArgumentError
    "{month-containing-#{date_string}}"
  end

  def year_for_month(month_string)
    Date.strptime(month_string, "%Y-%m").year
  rescue ArgumentError
    "{year-containing-#{month_string}}"
  end

end
