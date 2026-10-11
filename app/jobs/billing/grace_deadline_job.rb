module Billing
  # Holds a resident whose grace ran out, without waiting for Stripe.
  class GraceDeadlineJob < ApplicationJob

    queue_as :default

    def perform(entitlement_id)
      ResidentEntitlement.find_by(id: entitlement_id)&.expire_grace!
    end

  end
end
