# Starts Stripe Checkout for one hosted resident on one plan. Prices are USD,
# tax-exclusive; Stripe Tax adds VAT from the customer's address, and EU
# businesses can give a VAT ID for reverse charge.
#
# A resident has at most one unresolved Checkout session. Requests are
# serialized on the resident's entitlement row, and an open session is expired
# at Stripe before another is created, so two links (different plans, or the
# same plan an hour apart) can't both be paid. A session that was paid but not
# yet confirmed by the webhook blocks a new one until it is.
module Billing
  class Checkout

    def initialize(agent:, tier:, success_url:, cancel_url:, client: Billing.client)
      @agent = agent
      @tier = tier
      @success_url = success_url
      @cancel_url = cancel_url
      @client = client
    end

    # Returns the Checkout URL to send the owner to.
    def url
      raise NotConfigured, "The #{@tier.name} plan has no Stripe price configured" unless @tier.purchasable?

      customer = BillingCustomer.for!(@agent.account, client: @client)
      entitlement = ResidentEntitlement.for_agent!(@agent)

      entitlement.with_lock do
        if ResidentSubscription.live.exists?(agent: @agent)
          raise AlreadySubscribed, "#{@agent.name} already has a subscription; change it from Manage billing"
        end

        previous = entitlement.checkout_session_id
        resolve_previous!(previous) if previous.present?
        session = @client.v1.checkout.sessions.create(
          params(customer),
          { idempotency_key: "souls-house-checkout-#{@agent.id}-#{previous || 'first'}-#{@tier.id}" }
        )
        entitlement.update!(checkout_session_id: session.id)
        session.url
      end
    end

    private

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

    def params(customer)
      metadata = { agent_id: @agent.id.to_s, account_id: @agent.account_id.to_s, tier: @tier.id }
      {
        mode: "subscription",
        customer: customer.stripe_customer_id,
        client_reference_id: @agent.id.to_s,
        line_items: [ { price: @tier.price_id, quantity: 1 } ],
        subscription_data: { metadata: metadata, description: "#{@tier.name} hosting for #{@agent.name}" },
        metadata: metadata,
        automatic_tax: { enabled: true },
        tax_id_collection: { enabled: true },
        billing_address_collection: "required",
        customer_update: { address: "auto", name: "auto" },
        success_url: @success_url,
        cancel_url: @cancel_url
      }
    end

    def stripe_id(value)
      value.respond_to?(:id) ? value.id : value
    end

  end
end
