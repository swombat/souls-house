module Agents
  # The connections a guest seat carries, for the Guest residents card on the
  # residents page: for each membership, what the account the resident is a
  # guest in has shared with it (JXgGQY). Only offers that are still open
  # (switched on, pending or approved by the home) are listed; a declined,
  # revoked, withdrawn or expired row is not a share. One query for the list.
  class GuestSharedIntegrations

    def initialize(memberships)
      @memberships = memberships.to_a
    end

    # The memberships as JSON, each with an `integrations` list.
    def as_json(*)
      rows = shared_rows
      @memberships.map do |membership|
        shared = rows.select do |access|
          access.agent_id == membership.agent_id && access.service_connection.account_id == membership.account_id
        end
        membership.as_json.merge(integrations: shared.map { |access| present(access) })
      end
    end

    private

    def shared_rows
      return [] if @memberships.empty?

      AgentServiceAccess
        .enabled
        .where(home_approval: AgentServiceAccess::OPEN_HOME_APPROVALS)
        .where(agent_id: @memberships.map(&:agent_id).uniq)
        .joins(:service_connection)
        .where(service_connections: { account_id: @memberships.map(&:account_id).uniq })
        .includes(:service_connection)
        .order("service_connections.provider", "service_connections.id")
        .to_a
    end

    def present(access)
      connection = access.service_connection
      live = access.home_approval == "approved" && connection.status == "connected"
      status =
        if access.home_approval == "pending" then "awaiting home approval"
        elsif connection.status != "connected" then connection.status
        else "shared"
        end
      {
        provider: connection.provider,
        label: connection.provider == "github" ? connection.credential_metadata["repository"].presence || connection.display_label : connection.display_label,
        enabled: live,
        status: status
      }
    end

  end
end
