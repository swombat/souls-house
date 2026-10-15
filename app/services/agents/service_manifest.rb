require "yaml"

module Agents
  class ServiceManifest

    attr_reader :agent

    def initialize(agent)
      @agent = agent
    end

    def to_h
      {
        "version" => 1,
        "generated_at" => Time.current.utc.iso8601,
        "resident_id" => agent.uuid,
        "services" => connections.map { |connection| connection.runtime_entry(agent: agent) }
      }
    end

    def to_yaml
      to_h.to_yaml
    end

    def present?
      connections.any?
    end

    # Called after the snapshot reaches the runtime. A concurrent grant or
    # credential change must keep its pending state and its own queued job.
    def mark_reconciled!
      accesses.each do |access|
        connection = access.service_connection
        # Broker token-cache writes change updated_at without changing runtime
        # authority or enqueueing reconciliation. They must not strand a grant.
        unchanged_connections = ServiceConnection.where(
          id: connection.id, status: connection.status,
          credential_revision: connection.credential_revision
        )
        provisioned = access.enabled? && connections.include?(connection)
        AgentServiceAccess.where(
          id: access.id, enabled: access.enabled, updated_at: access.updated_at,
          service_connection_id: unchanged_connections.select(:id)
        ).update_all(
          provisioned_revision: provisioned ? connection.credential_revision : nil,
          provisioned_at: Time.current,
          provisioning_status: provisioned ? "provisioned" : "removed",
          provisioning_error_code: nil
        )
      end
    end

    private

    def accesses
      @accesses ||= agent.agent_service_accesses.includes(:service_connection).to_a
    end

    def connections
      return [] if agent.github_resident_import&.approval_error
      @connections ||= accesses
        .select(&:enabled?)
        .map(&:service_connection)
        .select { |connection| connection.status == "connected" }
    end

  end
end
