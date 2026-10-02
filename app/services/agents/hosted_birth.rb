module Agents
  class HostedBirth

    def self.default_model_id(account:, creator:)
      if HouseInference::Offering.configured? &&
          account.ai_credentials_manageable_by?(creator) &&
          !HouseInferenceGrant.where(user: creator).where.not(agent_id: nil).exists?
        HouseInference::Offering::MODEL_ID
      else
        Chat::MODELS.first.fetch(:model_id)
      end
    end

    def initialize(account:, creator:, attributes:, open_beginning: false)
      @account = account
      @creator = creator
      @attributes = attributes
      @open_beginning = open_beginning
    end

    def create!
      now = Time.current
      default_model = self.class.default_model_id(account: account, creator: creator)
      agent = account.agents.new({ model_id: default_model }.merge(attributes))
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

      HouseInferenceGrant.synchronize do
        Agents::HostedProvisioning.new(agent: agent, user: creator).prepare!(started_at: now)
        HouseInferenceGrant.assign!(agent, creator)
        ProvisionAgentJob.perform_later(agent.id)
      end
      agent
    end

    private

    attr_reader :account, :creator, :attributes, :open_beginning

  end
end
