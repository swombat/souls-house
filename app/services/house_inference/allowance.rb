module HouseInference
  # What the resident pages show about house-model funding: the resident's
  # own allowance (paid plan or free hosting) when it has one in force,
  # otherwise the per-user free grant.
  module Allowance

    def self.presentation(agent)
      entitlement = ResidentEntitlement.find_by(agent: agent)
      return entitlement.allowance_presentation if entitlement&.funds_calls?

      HouseInferenceGrant.find_by(agent: agent)&.presentation&.merge(source: "grant")
    end

  end
end
