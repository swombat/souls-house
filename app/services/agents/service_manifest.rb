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

    private

    def connections
      return [] if agent.github_resident_import&.approval_error
      @connections ||= agent.agent_service_accesses
        .enabled
        .includes(:service_connection)
        .map(&:service_connection)
        .select { |connection| connection.status == "connected" }
    end

  end
end
