module Billing
  # Backstop for the webhook path and the grace deadline job: retries events
  # that were recorded but never finished, and holds residents whose grace has
  # run out if their deadline job was lost.
  class SweepJob < ApplicationJob

    queue_as :default

    def perform(now: Time.current)
      StripeEvent.retryable(now).find_each do |event|
        event.touch
        ProcessStripeEventJob.perform_later(event.id)
      end

      ResidentEntitlement.grace_expired(now).find_each { |entitlement| entitlement.expire_grace!(now: now) }
    end

  end
end
