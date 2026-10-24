# Brings one Stripe subscription into the house. Never trusts the event's copy:
# it re-fetches the subscription from Stripe under a per-resident advisory
# lock, validates it against the account and the plan catalogue, and applies
# it. An older fetch can't land after a newer one.
module Billing
  class SubscriptionSync

    LOCK_NAMESPACE = 7_242_001 # "billing", for pg_advisory_xact_lock(int, int)

    def initialize(stripe_subscription_id, client: Billing.client, now: Time.current)
      @stripe_subscription_id = stripe_subscription_id
      @client = client
      @now = now
    end

    def call
      agent = agent_for(fetch)

      ApplicationRecord.transaction do
        ApplicationRecord.connection.execute(
          "SELECT pg_advisory_xact_lock(#{LOCK_NAMESPACE}, #{Integer(agent.id)})"
        )
        remote = fetch
        tier = validate!(remote, agent)
        subscription = record!(remote, agent, tier)
        ResidentEntitlement.for_agent!(agent).apply_subscription!(subscription, now: @now)
        subscription
      end
    end

    private

    def fetch
      @client.v1.subscriptions.retrieve(@stripe_subscription_id)
    end

    def agent_for(remote)
      agent_id = remote.metadata && remote.metadata["agent_id"]
      Agent.find_by(id: agent_id) ||
        raise(InvalidSubscription, "Subscription #{@stripe_subscription_id} names no resident here (#{agent_id.inspect})")
    end

    def validate!(remote, agent)
      if remote.metadata["agent_id"].to_s != agent.id.to_s
        raise InvalidSubscription, "Subscription #{@stripe_subscription_id} changed resident"
      end

      customer = BillingCustomer.find_by(account: agent.account)
      if customer.nil? || customer.stripe_customer_id != stripe_id(remote.customer)
        raise InvalidSubscription, "Subscription #{@stripe_subscription_id} belongs to another customer"
      end

      items = remote.items.data
      tier = items.one? && Tier.for_price(stripe_id(items.first.price))
      tier || raise(InvalidSubscription, "Subscription #{@stripe_subscription_id} has a price outside the plan catalogue")
    end

    def record!(remote, agent, tier)
      subscription = ResidentSubscription.find_or_initialize_by(stripe_subscription_id: remote.id)
      subscription.assign_attributes(
        agent: agent,
        account: agent.account,
        tier: tier.id,
        stripe_status: remote.status,
        current_period_end: period_end(remote),
        cancel_at_period_end: remote.cancel_at_period_end ? true : false,
        last_synced_at: @now
      )
      subscription.save!
      subscription
    end

    # Newer Stripe API versions keep the period on the subscription item.
    def period_end(remote)
      seconds = remote.items.data.first&.[](:current_period_end) || remote[:current_period_end]
      seconds && Time.zone.at(seconds)
    end

    def stripe_id(value)
      value.respond_to?(:id) ? value.id : value
    end

  end
end
