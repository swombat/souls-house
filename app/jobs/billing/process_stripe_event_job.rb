module Billing
  class ProcessStripeEventJob < ApplicationJob

    queue_as :default

    def perform(stripe_event_id)
      attempt = StripeEvent.claim(stripe_event_id)
      return if attempt.nil?

      event = StripeEvent.find(stripe_event_id)
      begin
        subscription_id = event.subscription_id
        SubscriptionSync.new(subscription_id).call if subscription_id.present?
        event.finish!(attempt: attempt, status: "processed")
      rescue StandardError => error
        event.finish!(attempt: attempt, status: "failed", error: "#{error.class}: #{error.message}".first(2_000))
        if error.is_a?(InvalidSubscription) || attempt >= StripeEvent::MAX_ATTEMPTS
          Rails.error.report(error, handled: true,
            context: { subsystem: "billing", stripe_event_id: event.stripe_event_id, attempts: attempt })
        end
      end
    end

  end
end
