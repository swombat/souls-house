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

    # Positive evidence that an attempt's create made no session: Stripe
    # answered it 400, and nothing was ever bound to the attempt. A 400 is
    # sent before anything is made, and a replay of a key whose first
    # request did make a session returns that session, not a 400. A
    # timeout, a 5xx, a rate limit or a reused key (IdempotencyError, not
    # an InvalidRequestError) is no such evidence, and the attempt stays.
    def rejected?(attempt, error)
      error.is_a?(Stripe::InvalidRequestError) && error.http_status == 400 && attempt.reload.stripe_session_id.nil?
    end

    # A completed session whose payment is over and never made: Stripe
    # completed Checkout with the payment still to come (a delayed method),
    # the first invoice was never paid, and Stripe has ended the
    # subscription as incomplete_expired, which it never leaves and which
    # voids the invoice. "unpaid" alone is not this: it is also a payment
    # still on its way (Mira, #1149).
    def ended_unpaid?(session, client:)
      return false unless session.status == "complete" && session.payment_status == "unpaid"

      id = session.subscription.is_a?(String) ? session.subscription : session.subscription&.id
      return false if id.blank?

      client.v1.subscriptions.retrieve(id).status == "incomplete_expired"
    end

    # Resolves the unresolved attempts in scope whose session Stripe says
    # has expired, and, with ended_unpaid, those whose session completed
    # and whose payment Stripe has ended unpaid. One with no session yet
    # (an uncertain create), still open, completed and paid or paying, or
    # that Stripe can't be asked about just now, stays.
    def release_expired!(attempts, client:, ended_unpaid: false)
      attempts.unresolved.where.not(stripe_session_id: nil).find_each do |attempt|
        session = client.v1.checkout.sessions.retrieve(attempt.stripe_session_id)
        if session.status == "expired" || (ended_unpaid && ended_unpaid?(session, client:))
          attempt.update!(resolved_at: Time.current)
        end
      rescue Stripe::StripeError
        next
      end
    end

  end
end
