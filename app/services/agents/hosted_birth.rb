module Agents
  class HostedBirth

    def self.default_model_id(account:, creator:)
      # In an account that pays per resident, the plan's allowance pays for the
      # house model, so it is offered whatever free grant the creator has used.
      paid_by_plan = Billing::BirthGate.requires_plan?(account)
      if HouseInference::Offering.configured? &&
          account.ai_credentials_manageable_by?(creator) &&
          (paid_by_plan || !HouseInferenceGrant.where(user: creator).where.not(agent_id: nil).exists?)
        HouseInference::Offering::DEFAULT_MODEL_ID
      else
        Chat::MODELS.first.fetch(:model_id)
      end
    end

    # paid: the birth was paid for at creation (Billing::PaidBirth). It
    # passes the billing gate, and gets no free house grant: the plan's
    # allowance replaces it.
    def initialize(account:, creator:, attributes:, open_beginning: false, paid: false)
      @account = account
      @creator = creator
      @attributes = attributes
      @open_beginning = open_beginning
      @paid = paid
    end

    def create!
      now = Time.current
      default_model = self.class.default_model_id(account: account, creator: creator)
      agent = account.agents.new({ model_id: default_model }.merge(attributes))

      Billing::BirthGate.refuse_unpaid!(account) unless paid

      # With new residents on their own VM, a birth either gets one or is
      # refused here, before anything is committed.
      policy = VmBirthPolicy.current
      policy.refuse!(kind: :birth, model_id: agent.model_id)

      if agent.system_prompt.blank? && !open_beginning
        agent.errors.add(:system_prompt, "can't be blank unless you explicitly choose an open beginning")
        raise ActiveRecord::RecordInvalid, agent
      end

      agent.assign_attributes(
        created_by_user: creator,
        active: true,
        runtime: "provisioning",
        birth_committed_at: now,
        provisioning_started_at: now
      )

      return create_on_vm!(agent, policy, now) if policy.enabled?

      HouseInferenceGrant.synchronize do
        Agents::HostedProvisioning.new(agent: agent, user: creator).prepare!(started_at: now)
        HouseInferenceGrant.assign!(agent, creator) unless paid
        ProvisionAgentJob.perform_later(agent.id)
      end
      agent
    end

    private

    attr_reader :account, :creator, :attributes, :open_beginning
    attr_reader :paid

    # The agent and its VM placement are committed together under the
    # admission lock, and the placement exists before credentials are
    # prepared, so preparation takes the VM path. ProvisionVmAgentJob orders
    # the server; nothing here touches local Docker.
    def create_on_vm!(agent, policy, now)
      HouseInferenceGrant.synchronize do
        policy.admit!(agent: agent, requested_by: creator, now: now)
        Agents::HostedProvisioning.new(agent: agent, user: creator).prepare!(started_at: now)
        HouseInferenceGrant.assign!(agent, creator) unless paid
      end
      ProvisionVmAgentJob.perform_later(agent.id)
      agent
    end

  end
end
