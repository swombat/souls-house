module HouseInference
  # What the resident pages show about house-model funding: the resident's
  # paid plan allowance when it has one in force, otherwise the free grant.
  module Allowance

    def self.presentation(agent)
      entitlement = ResidentEntitlement.find_by(agent: agent)
      return entitlement.allowance_presentation if entitlement&.paid?

      HouseInferenceGrant.find_by(agent: agent)&.presentation&.merge(source: "grant")
    end

  end
end
