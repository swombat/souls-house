# Starts Stripe Checkout for one hosted resident on one plan. Prices are USD,
# tax-exclusive; Stripe Tax adds VAT from the customer's address, and EU
# businesses can give a VAT ID for reverse charge.
module Billing
  class Checkout

    def initialize(agent:, tier:, success_url:, cancel_url:, client: Billing.client, now: Time.current)
      @agent = agent
      @tier = tier
      @success_url = success_url
      @cancel_url = cancel_url
      @client = client
      @now = now
    end

    # Returns the Checkout URL to send the owner to.
    def url
      raise NotConfigured, "The #{@tier.name} plan has no Stripe price configured" unless @tier.purchasable?
      if ResidentSubscription.live.exists?(agent: @agent)
        raise AlreadySubscribed, "#{@agent.name} already has a subscription; change it from Manage billing"
      end

      customer = BillingCustomer.for!(@agent.account, client: @client)
      ResidentEntitlement.for_agent!(@agent)
      session = @client.v1.checkout.sessions.create(params(customer), { idempotency_key: idempotency_key })
      session.url
    end

    private

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

    # A double click within the hour reuses the same open session.
    def idempotency_key
      "souls-house-checkout-#{@agent.id}-#{@tier.id}-#{@now.utc.strftime('%Y%m%d%H')}"
    end

  end
end
