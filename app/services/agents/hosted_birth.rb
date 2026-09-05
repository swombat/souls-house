module Agents
  class HostedBirth

    def initialize(account:, creator:, attributes:, open_beginning: false)
      @account = account
      @creator = creator
      @attributes = attributes
      @open_beginning = open_beginning
    end

    def create!
      now = Time.current
      agent = account.agents.new(attributes)
      if agent.system_prompt.blank? && !open_beginning
        agent.errors.add(:system_prompt, "can't be blank unless you explicitly choose an open beginning")
        raise ActiveRecord::RecordInvalid, agent
      end

      agent.assign_attributes(
        active: true,
        runtime: "provisioning",
        birth_committed_at: now,
        provisioning_started_at: now
      )

      Agents::HostedProvisioning.new(agent: agent, user: creator).prepare!(
        started_at: now
      )
      ProvisionAgentJob.perform_later(agent.id)
      agent
    end

    private

    attr_reader :account, :creator, :attributes, :open_beginning

  end
end
