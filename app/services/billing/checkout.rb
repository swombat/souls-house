# Starts Stripe Checkout for one hosted resident on one offer. Prices are USD,
# tax-exclusive; Stripe Tax adds VAT from the customer's address, and EU
# businesses can give a VAT ID for reverse charge.
#
# A resident has at most one unresolved Checkout session. Requests are
# serialized on the resident's entitlement row, and an open session is expired
# at Stripe before another is created, so two links (different plans, or the
# same plan an hour apart) can't both be paid. A session that was paid but not
# yet confirmed by the webhook blocks a new one until it is.
#
# Every attempt is a CheckoutAttempt row keyed by its Stripe idempotency key,
# holding the offer and the grant it was authorised by, committed under the
# lock before Stripe is called. A replay of the key (the answer was lost)
# sends the same payload whatever the account's grants are by then and
# recovers the session Stripe made. An attempt at another offer has another
# key: before it is made, every unresolved attempt of the resident is
# replayed to learn its session and expire it, or marked abandoned if its key
# can no longer be replayed, so nothing is overwritten or left open.
module Billing
  class Checkout

    def initialize(agent:, tier:, success_url:, cancel_url:, rate: "standard", client: Billing.client)
      @agent = agent
      @offer = tier.offer(rate)
      @success_url = success_url
      @cancel_url = cancel_url
      @client = client
    end

    # Returns the Checkout URL to send the owner to.
    def url
      raise NotConfigured, "The #{@offer.name} plan has no Stripe price configured" unless @offer.purchasable?

      customer = BillingCustomer.for!(@agent.account, client: @client)
      entitlement = ResidentEntitlement.for_agent!(@agent)

      # The lock is a transaction: the attempt is committed when it ends,
      # before Stripe is called, so it survives whatever happens next.
      attempt = entitlement.with_lock { pin!(entitlement, customer) }
      begin
        session = @client.v1.checkout.sessions.create(params(customer, attempt), { idempotency_key: attempt.idempotency_key })
      rescue Stripe::IdempotencyError => error
        # A replay Stripe refuses: the attempt's payload can no longer be
        # rebuilt. It is abandoned, and the next request gets a fresh key.
        attempt.update!(abandoned_at: Time.current)
        Rails.error.report(error, handled: true, context: { subsystem: "billing", checkout_attempt_id: attempt.id })
        raise NotReady, "An earlier attempt for #{@agent.name} couldn't be reconciled with Stripe. Try again."
      end
      entitlement.with_lock do
        attempt.update!(stripe_session_id: session.id)
        entitlement.update!(checkout_session_id: session.id)
      end
      session.url
    end

    private

    # Under the lock: the attempt this request is, found by its key (a
    # replay) or made now and authorised now.
    def pin!(entitlement, customer)
      if ResidentSubscription.live.exists?(agent: @agent)
        raise AlreadySubscribed, "#{@agent.name} already has a subscription; change it from Manage billing"
      end

      previous = entitlement.checkout_session_id
      resolve_previous!(previous) if previous.present?
      key = key_for(previous)
      if (replay = CheckoutAttempt.unresolved.find_by(idempotency_key: key))
        return replay
      end

      recover_unresolved!(customer)
      unless @agent.account.eligible_for?(@offer.rate)
        raise NotEligible, "This account can't buy plans at that rate."
      end
      CheckoutAttempt.create!(agent: @agent, idempotency_key: key, offer_id: @offer.id,
        billing_code_redemption: @agent.account.grant_for(@offer.rate))
    end

    # Deterministic per (resident, previous session, offer), so an uncertain
    # create is replayed; past an abandoned attempt the key moves on, since
    # Stripe would refuse the old one forever.
    def key_for(previous)
      base = "souls-house-checkout-#{@agent.id}-#{previous || 'first'}-#{@offer.id}"
      abandoned = CheckoutAttempt.where(agent: @agent).where.not(abandoned_at: nil)
        .where("idempotency_key = ? OR idempotency_key LIKE ?", base, "#{base}-retry-%").count
      abandoned.zero? ? base : "#{base}-retry-#{abandoned}"
    end

    # An attempt whose answer was lost may have a session open at Stripe.
    # Replaying its key with its own payload returns that session; it is
    # recorded, and expired if still open. A paid one blocks, as a recorded
    # paid session does. A key Stripe refuses to replay (the payload can no
    # longer be rebuilt) is abandoned, and said so.
    def recover_unresolved!(customer)
      CheckoutAttempt.unresolved.where(agent: @agent).order(:id).each do |attempt|
        begin
          session = @client.v1.checkout.sessions.create(params(customer, attempt), { idempotency_key: attempt.idempotency_key })
        rescue Stripe::IdempotencyError => error
          attempt.update!(abandoned_at: Time.current)
          Rails.error.report(error, handled: true, context: { subsystem: "billing", checkout_attempt_id: attempt.id })
          next
        end
        attempt.update!(stripe_session_id: session.id)
        resolve_previous!(session.id)
      end
    end

    # An open session is expired so it can no longer be paid. A completed one
    # whose subscription we haven't seen end yet means a payment is in flight.
    def resolve_previous!(session_id)
      session = @client.v1.checkout.sessions.retrieve(session_id)
      case session.status
      when "open"
        @client.v1.checkout.sessions.expire(session_id)
      when "complete"
        recorded = ResidentSubscription.find_by(stripe_subscription_id: stripe_id(session.subscription))
        if recorded.nil? || recorded.live?
          raise AlreadySubscribed, "A payment for #{@agent.name} is still being confirmed by Stripe. Try again in a minute."
        end
      end
    end

    # The payload for an attempt: the offer it was made for and the grant it
    # was authorised by, so a replay matches its key. A standard session's
    # payload is what it was before rates existed (the key is deterministic
    # across deploys); only an at-cost session carries its rate.
    def params(customer, attempt)
      offer = offer_for(attempt)
      metadata = { agent_id: @agent.id.to_s, account_id: @agent.account_id.to_s, tier: offer.tier.id }
      unless offer.standard?
        metadata[:rate] = offer.rate
        metadata[:redemption_id] = attempt.billing_code_redemption_id.to_s
      end
      {
        mode: "subscription",
        customer: customer.stripe_customer_id,
        client_reference_id: @agent.id.to_s,
        line_items: [ { price: offer.price_id, quantity: 1 } ],
        subscription_data: { metadata: metadata, description: "#{offer.name} hosting for #{@agent.name}" },
        metadata: metadata,
        automatic_tax: { enabled: true },
        tax_id_collection: { enabled: true },
        billing_address_collection: "required",
        customer_update: { address: "auto", name: "auto" },
        success_url: @success_url,
        cancel_url: @cancel_url
      }
    end

    def offer_for(attempt)
      return @offer if attempt.offer_id == @offer.id

      Tier.all.flat_map(&:offers).find { |offer| offer.id == attempt.offer_id } ||
        raise(NotConfigured, "Attempt #{attempt.id} names an offer that is no longer in the catalogue")
    end

    def stripe_id(value)
      value.respond_to?(:id) ? value.id : value
    end

  end
end
