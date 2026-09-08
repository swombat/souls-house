module Agents
  class ResidentIntegrations
    def initialize(account, agents)
      @connections = account.service_connections.order(:provider, :id).to_a
      @accesses = AgentServiceAccess.where(agent_id: agents.map(&:id)).index_by { |access| [ access.agent_id, access.service_connection_id ] }
      @telegram_available = agents.any?(&:telegram_configured?)
    end

    def for(agent)
      icons = @connections.map do |connection|
        access = @accesses[[ agent.id, connection.id ]]
        enabled = access&.enabled? && connection.status == "connected"
        {
          provider: connection.provider,
          label: connection.provider == "github" ? connection.credential_metadata["repository"].presence || connection.display_label : connection.display_label,
          enabled: !!enabled,
          status: enabled ? (access.provisioning_status.presence || "enabled") : "disabled"
        }
      end
      if @telegram_available
        icons.unshift(provider: "telegram", label: "Telegram", enabled: agent.telegram_configured?, status: agent.telegram_configured? ? "enabled" : "disabled")
      end
      icons
    end
  end
end
