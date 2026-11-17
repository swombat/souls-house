module HouseInference
  # What the resident pages show about house-model funding: through the
  # resident's plan or free hosting when it has one in force, otherwise
  # through the grant that put it on the house. Either way the allowance is
  # the account's (Billing::Allowance).
  module Allowance

    def self.presentation(agent)
      entitlement = ResidentEntitlement.find_by(agent: agent)
      return entitlement.allowance_presentation if entitlement&.funds_calls?

      HouseInferenceGrant.find_by(agent: agent)&.presentation&.merge(source: "grant")
    end

  end
end
