module Admin
  class AccountUsageReport

    SESSION_KEY = "COALESCE(NULLIF(session_id, ''), 'interaction-' || id::text)".freeze

    def initialize(account, now: Time.current)
      @account = account
      @now = now
    end

    def call
      conversation_counts = ChatAgent.where(agent_id: agents.map(&:id))
        .group(:agent_id).count
      run_counts = interactions.group(:agent_id).count
      session_counts = sessions.group(:agent_id).count(Arel.sql("DISTINCT #{SESSION_KEY}"))
      last_activity = interactions.group(:agent_id).maximum(:started_at)

      {
        generated_at: @now,
        summary: {
          agents: agents.size,
          active_agents: agents.count { |agent| agent.active? && !agent.paused? },
          conversations: @account.chats.count,
          sessions: session_counts.values.sum,
          runs: run_counts.values.sum,
          last_activity_at: last_activity.values.compact.max
        },
        agents: agents.map do |agent|
          agent_json(agent).merge(
            conversations: conversation_counts.fetch(agent.id, 0),
            sessions: session_counts.fetch(agent.id, 0),
            runs: run_counts.fetch(agent.id, 0),
            last_activity_at: last_activity[agent.id]
          )
        end,
        activity: activity,
        recent_sessions: recent_sessions,
        recent_conversations: recent_conversations,
        integrations: integrations,
        ai_providers: Account::AI_PROVIDERS.keys.map do |provider|
          { provider: provider, configured: @account.public_send("#{provider}_api_key").present? }
        end
      }
    end

    private

    def agents
      @agents ||= @account.agents.order(:name).includes(agent_service_accesses: :service_connection).to_a
    end

    def interactions
      AgentRuntimeInteraction.where(agent_id: agents.map(&:id))
    end

    def sessions
      # A rejected busy retry did not actually run a session.
      interactions.where("transport_status IS DISTINCT FROM 409 OR runtime_status IS DISTINCT FROM 'already_running'")
    end

    def agent_json(agent)
      # Deliberate allowlist: never serialize prompts, credentials or runtime output.
      {
        id: agent.to_param, name: agent.name, created_at: agent.created_at,
        active: agent.active?, paused: agent.paused?, runtime: agent.runtime,
        health_state: agent.health_state, last_health_check_at: agent.last_health_check_at,
        model: agent.model_label, model_id: agent.model_id, reasoning_effort: agent.reasoning_effort,
        thinking_enabled: agent.thinking_enabled?, thinking_budget: agent.thinking_budget,
        scheduled_wakes_enabled: agent.scheduled_wakes_enabled?,
        heartbeat_wakes_per_day: agent.heartbeat_wakes_per_day,
        persistent_session: agent.persistent_session?, persistent_wake_session: agent.persistent_wake_session?,
        enabled_tools: agent.enabled_tools, voice_enabled: agent.voiced?,
        container_memory_mb: agent.container_memory_mb,
        backup_interval_hours: agent.backup_interval_hours,
        storage: agent.storage_usage,
        telegram: { configured: agent.telegram_configured?, username: agent.telegram_bot_username },
        provider_auth: Agent::OAUTH_ACCOUNT_PROVIDERS.map do |provider|
          {
            provider: provider, mode: agent.provider_auth_mode(provider),
            status: agent.provider_connection(provider)["status"]
          }
        end,
        services: agent.agent_service_accesses.filter_map do |access|
          connection = access.service_connection
          next unless connection.account_id == @account.id

          {
            label: connection.display_label, provider: connection.provider,
            enabled: access.enabled?, status: connection.status,
            provisioning_status: access.provisioning_status
          }
        end
      }
    end

    def activity
      first_day = @now.utc.to_date - 29
      range = Time.utc(first_day.year, first_day.month, first_day.day)..@now
      # Rails persists these timestamp-without-time-zone columns in UTC.
      runs = interactions.where(started_at: range).group(Arel.sql("DATE(started_at)")).count
      daily_sessions = sessions.where(started_at: range)
        .group(Arel.sql("DATE(started_at)"))
        .count(Arel.sql("DISTINCT (agent_id, #{SESSION_KEY})"))
      conversations = @account.chats.where(created_at: range)
        .group(Arel.sql("DATE(created_at)")).count
      (first_day..@now.utc.to_date).map do |date|
        {
          date: date.iso8601, sessions: daily_sessions.fetch(date, 0),
          runs: runs.fetch(date, 0), conversations: conversations.fetch(date, 0)
        }
      end
    end

    def recent_sessions
      rows = sessions.group(:agent_id, Arel.sql(SESSION_KEY))
        .order(Arel.sql("MAX(started_at) DESC")).limit(10)
        .pluck(:agent_id, Arel.sql(SESSION_KEY), Arel.sql("MIN(started_at)"),
          Arel.sql("MAX(started_at)"), Arel.sql("COUNT(*)"))
      by_id = agents.index_by(&:id)
      rows.map do |agent_id, session_id, first_at, last_at, runs|
        {
          agent_id: by_id.fetch(agent_id).to_param, agent_name: by_id.fetch(agent_id).name,
          session_id: session_id, first_at: first_at, last_at: last_at, runs: runs
        }
      end
    end

    def recent_conversations
      chats = @account.chats.order(updated_at: :desc, id: :desc).includes(:agents).limit(10).to_a
      counts = Message.where(chat_id: chats.map(&:id)).group(:chat_id).count
      chats.map do |chat|
        {
          id: chat.to_param, title: chat.title_or_default, updated_at: chat.updated_at,
          messages: counts.fetch(chat.id, 0), agents: chat.agents.map(&:name),
          archived: chat.archived_at.present?, discarded: chat.discarded_at.present?
        }
      end
    end

    def integrations
      connections = @account.service_connections.includes(agent_service_accesses: :agent).order(:provider, :id)
      rows = connections.map do |connection|
        {
          provider: connection.provider, label: connection.display_label,
          status: connection.status, scope: connection.management_scope,
          enabled_for_new_agents: connection.enabled_for_new_agents?,
          agents: connection.agent_service_accesses.select { |access| access.enabled? && access.agent.account_id == @account.id }
            .map { |access| access.agent.name }
        }
      end
      [ [ "GitHub commits", @account.github_integration ], [ "X posting", @account.x_integration ] ].each do |label, integration|
        next unless integration

        rows << {
          provider: label, label: label, scope: "account",
          status: !integration.enabled? ? "disabled" : (integration.connected? ? "connected" : "disconnected"),
          agents: []
        }
      end
      if @account.github_pat.present?
        rows << {
          provider: "github", label: "GitHub repository access", scope: "account",
          status: "configured", agents: []
        }
      end
      OuraIntegration.where(user_id: @account.memberships.confirmed.select(:user_id))
        .where.not(id: connections.filter_map(&:legacy_oura_integration_id))
        .includes(:user).each do |integration|
        rows << {
          provider: "oura", label: "Oura · #{integration.user.email_address}", scope: "legacy personal",
          status: !integration.enabled? ? "disabled" : (integration.connected? ? "connected" : "disconnected"),
          agents: []
        }
      end
      rows
    end

  end
end
