module Agents
  class RotateCredentials

    class Error < StandardError; end

    def self.owner(agent)
      agent.outbound_api_key&.user || raise(Error, "Restore requires the resident's outbound credential owner")
    end

    def self.call(agent)
      agent.with_lock do
        user = owner(agent)
        # All resident-scoped keys are invalidated, not only the primary key.
        # Keep restic's encryption password: changing it would strand backups.
        agent.update!(outbound_api_key: nil, outbound_api_token: nil)
        ApiKey.where(agent_id: agent.id).find_each(&:destroy!)
        key = ApiKey.generate_for(user, name: "agent:#{agent.id}:outbound", agent: agent)
        agent.update!(outbound_api_key: key, outbound_api_token: key.raw_token,
          trigger_bearer_token: "tr_#{SecureRandom.hex(24)}")
      end
    end

  end
end
