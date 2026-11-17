module Billing
  # The house-model allowance: one per account, never per resident or per
  # person (Daniel, eRyZBY JbaKgE, 2026-11-17: "the allowances go to the
  # accounts… any plan has a $10 allowance basically across all accounts").
  # Tier::ACCOUNT_ALLOWANCE_USD a UTC month, shared by every resident the
  # account funds at the standard rate, by whatever path it is funded: a paid
  # or included plan, a granted plan, free hosting from before plans, or a
  # resident put on the house. During the free trial it is that amount for
  # the whole trial, not a month of it (Trial; Daniel, YGBNNJ jwMQpE:
  # "maximum cost is $10 per user that signs up").
  #
  # Spend is everything the account's residents drew from the house this
  # month, whichever path paid for the call, so a second path never finds a
  # second $10.
  module Allowance

    def self.monthly_usd = Tier::ACCOUNT_ALLOWANCE_USD

    # What the account's residents drew from house models in these months
    # (a month, or a range of them). In-flight calls count at their
    # reservation until settled.
    def self.spent(account_id, month: HouseInference::Offering.month)
      calls(account_id).where(month: month).sum(:charge_usd)
    end

    # A call belongs to the account of the resident that made it. A call
    # recorded without a resident counts for the account of the ledger it
    # was drawn on.
    def self.calls(account_id)
      agents = Agent.where(account_id: account_id).select(:id)
      unattributed = HouseInferenceCall.where(agent_id: nil)
      HouseInferenceCall.where(agent_id: agents)
        .or(unattributed.where(resident_entitlement_id: ResidentEntitlement.where(account_id: account_id).select(:id)))
        .or(unattributed.where(house_inference_grant_id: HouseInferenceGrant.where(agent_id: agents).select(:id)))
    end

    # This month's ceiling. In the free trial it is what the account didn't
    # draw in the trial's earlier months, so ceiling minus this month's
    # spend is the allowance minus everything drawn since the trial began.
    def self.limit(account_id, month: HouseInference::Offering.month)
      started = Trial.allowance_started_at(account_id)
      return monthly_usd unless started

      before = spent(account_id, month: started.utc.to_date.beginning_of_month...month)
      [ monthly_usd - before, BigDecimal("0") ].max
    end

    def self.remaining(account_id, month: HouseInference::Offering.month)
      [ limit(account_id, month:) - spent(account_id, month:), BigDecimal("0") ].max
    end

  end
end
