# Checkout grants nothing. It commits an immutable attempt before Stripe, keeps
# unresolved creates blocking, and serializes through publication with webhooks.
module Billing
  class Checkout

    REPLAY_WINDOW = 23.hours # Stripe may prune keys after 24h.
    OPERATION_BUDGET = 30 # cooperative seconds, checked between HTTP calls

    def initialize(agent:, tier:, success_url:, cancel_url:, rate: "standard", client: Billing.client)
      @agent, @offer, @client = agent, tier.offer(rate), client
      @success_url, @cancel_url = success_url, cancel_url
    end

    def url
      @deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + OPERATION_BUDGET
      CheckoutLock.synchronize(@agent) do
        if ResidentSubscription.live.exists?(agent: @agent)
          raise AlreadySubscribed, "#{@agent.name} already has a subscription; change it from Manage billing"
        end
        entitlement = ResidentEntitlement.for_agent!(@agent)
        customer = remote { BillingCustomer.for!(@agent.account, client: @client) }
        attempt = BillingCheckoutAttempt.unresolved.find_by(agent: @agent)
        if attempt
          session = recover!(attempt)
          if attempt.tier == @offer.tier.id && attempt.rate == @offer.rate && session.status == "open"
            publish!(attempt, session, entitlement)
            next session.url
          end
          settle!(session)
          attempt.update!(resolved_at: Time.current)
        elsif !BillingCheckoutAttempt.exists?(agent: @agent)
          settle_legacy!(customer, entitlement)
        end

        grant = check_offer!
        key = "souls-house-checkout-#{SecureRandom.uuid}"
        payload = params(customer, key, grant)
        # No surrounding transaction: this write has committed when create runs.
        attempt = BillingCheckoutAttempt.create!(agent: @agent, account: @agent.account,
          tier: @offer.tier.id, rate: @offer.rate, stripe_price_id: payload[:line_items].first[:price],
          billing_code_redemption: grant,
          idempotency_key: key, create_params: payload)
        session = recover!(attempt)
        publish!(attempt, session, entitlement)
        session.url
      end
    end

    private

    def check_offer!
      raise NotConfigured, "The #{@offer.name} plan has no Stripe price configured" unless @offer.purchasable?
      grant = @agent.account.grant_for(@offer.rate)
      unless @offer.standard? || grant
        raise NotEligible, "This account can't buy plans at that rate. Redeem your billing code first."
      end
      if @offer.at_cost? && HouseInference::Offering.find(@agent.model_id.to_s)
        raise NotEligible, "At cost includes no house-model allowance. Choose a model on your own subscription or key in the resident's settings first."
      end
      grant
    end

    def recover!(attempt)
      if attempt.stripe_session_id?
        return remote { @client.v1.checkout.sessions.retrieve(attempt.stripe_session_id) }
      end
      if attempt.created_at < REPLAY_WINDOW.ago
        raise NotReady, "An earlier Checkout for #{@agent.name} needs operator reconciliation. Contact #{Billing.contact_email}; do not pay another link."
      end

      session = remote do
        @client.v1.checkout.sessions.create(attempt.create_params.deep_symbolize_keys,
          { idempotency_key: attempt.idempotency_key })
      end
      attempt.update!(stripe_session_id: session.id)
      # Read live state: a replay can return the originally cached open response
      # even after the session completed or expired.
      remote { @client.v1.checkout.sessions.retrieve(session.id) }
    end

    def publish!(attempt, session, entitlement)
      raise NotReady, "This Checkout is no longer open. Please try again." unless session.status == "open" && session.url.present?

      entitlement.update!(checkout_session_id: attempt.stripe_session_id)
    end

    def settle!(session)
      case session.status
      when "open"
        expired = remote { @client.v1.checkout.sessions.expire(session.id) }
        raise NotReady, "The earlier Checkout could not be expired. Please try again." unless expired.status == "expired"
      when "complete"
        recorded = ResidentSubscription.find_by(stripe_subscription_id: stripe_id(session.subscription),
          agent: @agent, account: @agent.account)
        if recorded.nil? || recorded.live?
          raise AlreadySubscribed, "A payment for #{@agent.name} is still being confirmed by Stripe. Try again in a minute."
        end
      when "expired"
        # Safe to replace.
      else
        raise NotReady, "Stripe hasn't confirmed the earlier Checkout's state. Please try again."
      end
    end

    def settle_legacy!(customer, entitlement)
      ids = []
      ids << entitlement.checkout_session_id if entitlement.checkout_session_id?
      cursor = nil
      loop do
        page = remote do
          @client.v1.checkout.sessions.list({ customer: customer.stripe_customer_id, limit: 100, starting_after: cursor }.compact)
        end
        page.data.each do |session|
          ids << session.id if session.client_reference_id.to_s == @agent.id.to_s && session.mode == "subscription"
        end
        break unless page.has_more

        next_cursor = page.data.last&.id
        raise NotReady, "Stripe's Checkout listing is incomplete. Please try again." if next_cursor.blank? || next_cursor == cursor

        cursor = next_cursor
      end
      ids.uniq.each { |id| settle!(remote { @client.v1.checkout.sessions.retrieve(id) }) }
    end

    def params(customer, key, grant)
      metadata = { agent_id: @agent.id.to_s, account_id: @agent.account_id.to_s,
        tier: @offer.tier.id, checkout_attempt: key }
      unless @offer.standard?
        metadata.merge!(rate: @offer.rate, redemption_id: grant.id.to_s)
      end
      {
        mode: "subscription", customer: customer.stripe_customer_id, client_reference_id: @agent.id.to_s,
        line_items: [ { price: @offer.price_id, quantity: 1 } ],
        subscription_data: { metadata: metadata, description: "#{@offer.name} hosting for #{@agent.name}" },
        metadata: metadata, automatic_tax: { enabled: true }, tax_id_collection: { enabled: true },
        billing_address_collection: "required", customer_update: { address: "auto", name: "auto" },
        success_url: @success_url, cancel_url: @cancel_url
      }
    end

    def remote
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= @deadline
        raise NotReady, "Stripe is taking too long. Your Checkout is kept; please try again."
      end
      yield
    end

    def stripe_id(value) = value.respond_to?(:id) ? value.id : value

  end
end
