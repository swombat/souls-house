module Billing
  # Backstop for the webhook path and the grace deadline job: retries events
  # that were recorded but never finished, escalates one whose worker died on
  # its last attempt, and ends the paid plan of residents whose grace has run
  # out if their deadline job was lost.
  class SweepJob < ApplicationJob

    class AbandonedEvent < StandardError; end

    queue_as :default

    def perform(now: Time.current)
      StripeEvent.abandoned(now).find_each do |event|
        next unless StripeEvent.where(id: event.id, status: "processing", attempts: event.attempts)
          .update_all(status: "failed", last_error: "Worker lost on the final attempt", updated_at: now) == 1

        Rails.error.report(AbandonedEvent.new("Stripe event #{event.stripe_event_id} abandoned after #{event.attempts} attempts"),
          handled: true, context: { subsystem: "billing", stripe_event_id: event.stripe_event_id })
      end

      StripeEvent.retryable(now).find_each { |event| ProcessStripeEventJob.perform_later(event.id) }

      ResidentEntitlement.grace_expired(now).find_each { |entitlement| entitlement.expire_grace!(now: now) }

      ResidentBirthOrder.expired(now).find_each do |order|
        PaidBirth.new.abandon_expired!(order)
      rescue Stripe::StripeError => error
        Rails.error.report(error, handled: true, context: { subsystem: "billing", birth_order_id: order.id })
      end
    end

  end
end
