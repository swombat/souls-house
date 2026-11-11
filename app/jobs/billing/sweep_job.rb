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

      # An unreadable item's hold runs out even if Stripe sends nothing more.
      ResidentSubscription.untrusted_expired(now).find_each do |row|
        ApplicationRecord.transaction do
          SubscriptionSync.lock!(row.account_id)
          ResidentEntitlement.for_agent!(row.agent).expire_untrusted!(row, now: now)
        end
      end

      # A sent item order is never abandoned: it is born, or tried again.
      ResidentBirthOrder.items_unborn(now).find_each do |order|
        PaidBirth.new.resume_item!(order)
      rescue StandardError => error
        Rails.error.report(error, handled: true, context: { subsystem: "billing", birth_order_id: order.id })
      end

      # One order that can't be settled (a busy account, an item not yet found)
      # is reported and left for the next pass; the rest still expire.
      ResidentBirthOrder.expired(now).find_each do |order|
        PaidBirth.new.abandon_expired!(order)
      rescue StandardError => error
        Rails.error.report(error, handled: true, context: { subsystem: "billing", birth_order_id: order.id })
      end

      # An End plan sent with no answer finishes with no browser; an unsent
      # quote left open is dropped. One that can't be settled is reported
      # and left for the next pass.
      BillingCheckoutAttempt.unresolved.where(kind: EndItem::KIND).find_each do |attempt|
        EndItem.new(agent: attempt.agent, now: now).resume!(attempt)
      rescue StandardError => error
        Rails.error.report(error, handled: true, context: { subsystem: "billing", checkout_attempt_id: attempt.id })
      end

      # A Keep whose answer or sync was lost: finished from what the
      # subscription shows.
      BillingCheckoutAttempt.unresolved.where(kind: EndItem::KEEP).find_each do |attempt|
        EndItem.new(agent: attempt.agent, now: now).resume_keep!(attempt)
      rescue StandardError => error
        Rails.error.report(error, handled: true, context: { subsystem: "billing", checkout_attempt_id: attempt.id })
      end
    end

  end
end
