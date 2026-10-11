module Billing
  class ProcessStripeEventJob < ApplicationJob

    queue_as :default

    def perform(stripe_event_id)
      event = StripeEvent.find_by(id: stripe_event_id)
      return if event.nil? || event.processed?

      event.update!(status: "processing", attempts: event.attempts + 1)
      subscription_id = event.subscription_id
      SubscriptionSync.new(subscription_id).call if subscription_id.present?
      event.update!(status: "processed", processed_at: Time.current, last_error: nil)
    rescue StandardError => error
      raise if event.nil?

      event.update!(status: "failed", last_error: "#{error.class}: #{error.message}".first(2_000))
      if error.is_a?(InvalidSubscription) || event.attempts >= StripeEvent::MAX_ATTEMPTS
        Rails.error.report(error, handled: true,
          context: { subsystem: "billing", stripe_event_id: event.stripe_event_id, attempts: event.attempts })
      end
    end

  end
end
