module Billing
  # The Stripe Checkout session behind a committed attempt: the part a
  # resident's Checkout (Billing::Checkout, BillingCheckoutAttempt) and an
  # account plan's (Billing::PlanCheckout, AccountPlanCheckoutAttempt) share.
  # Everything about what is being bought, who may buy it and what a
  # completed session means stays with each of them.
  #
  # The attempt is committed before Stripe is asked. A create with no answer
  # is replayed under the same key within REPLAY_WINDOW, never rotated; past
  # it, only an operator binds the session (Billing::CheckoutRecovery).
  module CheckoutSession

    REPLAY_WINDOW = 23.hours # Stripe may prune keys after 24h.

    module_function

    # The attempt's session, created (or replayed) if it has none yet, read
    # live. remote wraps each Stripe call (a caller's deadline).
    def recover!(attempt, client:, stale:, remote: ->(&call) { call.call })
      return remote.call { client.v1.checkout.sessions.retrieve(attempt.stripe_session_id) } if attempt.stripe_session_id?
      raise NotReady, stale if attempt.created_at < REPLAY_WINDOW.ago

      session = remote.call do
        client.v1.checkout.sessions.create(attempt.create_params.deep_symbolize_keys,
          { idempotency_key: attempt.idempotency_key })
      end
      attempt.update!(stripe_session_id: session.id)
      # Read live state: a replay can return the originally cached open
      # response even after the session completed or expired.
      remote.call { client.v1.checkout.sessions.retrieve(session.id) }
    end

    # Closes an open session so it can't be paid. Raises unless Stripe says
    # it is expired.
    def expire!(session, client:, remote: ->(&call) { call.call })
      expired = remote.call { client.v1.checkout.sessions.expire(session.id) }
      raise NotReady, "The earlier Checkout could not be expired. Please try again." unless expired.status == "expired"
    end

    # Resolves the unresolved attempts in scope whose session Stripe says
    # has expired. One with no session yet (an uncertain create), still
    # open, completed, or that Stripe can't be asked about just now, stays.
    def release_expired!(attempts, client:)
      attempts.unresolved.where.not(stripe_session_id: nil).find_each do |attempt|
        session = client.v1.checkout.sessions.retrieve(attempt.stripe_session_id)
        attempt.update!(resolved_at: Time.current) if session.status == "expired"
      rescue Stripe::StripeError
        next
      end
    end

  end
end
