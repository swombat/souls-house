# Moves one resident's live plan to another tier at the same rate: a Stripe
# subscription item price change, prorated by Stripe for the rest of the
# period, then brought in through SubscriptionSync so the house's row and the
# allowance follow at once (the month's ceiling keeps its high-water mark).
# Stripe's portal can't do this here, its plan list is empty by the at-cost
# rule (docs/proposals/2026-10-28-billing-codes-at-cost.md), so it is a house
# action on the Billing tab. The rate never changes here: moving a plan to
# at cost is a different, scheduled act.
#
# The resident's own server, if it has one, keeps its size until resizing
# ships; the Billing tab says so.
module Billing
  class PlanChange

    class Refused < StandardError; end

    def initialize(agent:, tier:, client: Billing.client)
      @agent = agent
      @tier = tier
      @client = client
    end

    # Returns the synced ResidentSubscription on the new plan.
    #
    # In three steps, so nothing Stripe has done can be undone locally:
    #  0. Bring in what Stripe has now, in SubscriptionSync's own committed
    #     transaction: a change whose answer was lost has already happened
    #     there, and that reconciliation must stand whatever is decided next,
    #     including "already on that plan".
    #  1. Under the account advisory lock SubscriptionSync takes (taken
    #     first, so this and the webhook never hold the entitlement row and
    #     the lock in opposite orders): decide, and give the change its own
    #     identity, the subscription's change count, committed when this
    #     transaction ends, before Stripe is called. A failure after the
    #     remote change can't roll it back into a key Stripe would replay
    #     instead of performing the next change.
    #  2. The Stripe update under that key. Setting a price Stripe already has
    #     changes nothing, so a change performed twice is harmless; one
    #     replayed instead of performed is not.
    #  3. SubscriptionSync, which takes the same lock, so the house's row and
    #     the allowance follow at once. What it returns is what Stripe has,
    #     and is what the caller should say.
    def call
      entitlement = ResidentEntitlement.for_agent!(@agent)
      current = entitlement.current_subscription
      unless current&.live? && entitlement.paid?
        raise Refused, "#{@agent.name} has no paid plan to change. Choose a plan first."
      end
      sync_class.new(current.stripe_subscription_id, client: @client).call(agent: @agent)

      remote_id, offer, item_id, from, count, single = ApplicationRecord.transaction do
        SubscriptionSync.lock!(@agent.account_id)
        entitlement.reload
        subscription = entitlement.current_subscription
        unless subscription&.live? && entitlement.paid?
          raise Refused, "#{@agent.name} has no paid plan to change. Choose a plan first."
        end
        raise Refused, "#{@agent.name} is already on #{@tier.name}." if subscription.tier == @tier.id

        offer = @tier.offer(subscription.rate)
        raise NotConfigured, "The #{offer.name} plan has no Stripe price configured" unless offer.purchasable?

        remote = @client.v1.subscriptions.retrieve(subscription.stripe_subscription_id)
        item = item_for(remote, subscription)
        from = item.price.respond_to?(:id) ? item.price.id : item.price
        subscription.update!(plan_changes_count: subscription.plan_changes_count + 1)
        [ remote.id, offer, item.id, from, subscription.plan_changes_count, remote.items.data.one? ]
      end

      params = { items: [ { id: item_id, price: offer.price_id } ], proration_behavior: "create_prorations" }
      # A subscription that is this resident alone describes it; one shared
      # by the account's residents doesn't.
      params.merge!(description: "#{offer.name} hosting for #{@agent.name}", metadata: { tier: offer.tier.id }) if single
      @client.v1.subscriptions.update(remote_id, params,
        { idempotency_key: "souls-house-plan-change-#{remote_id}-#{count}-#{from}-#{offer.price_id}" })
      sync_class.new(remote_id, client: @client).call(agent: @agent)
    end

    private

    # This resident's item: the one the house recorded, or a legacy
    # subscription's only item.
    def item_for(remote, subscription)
      items = remote.items.data
      item = if subscription.stripe_subscription_item_id
        items.find { |row| row.id == subscription.stripe_subscription_item_id }
      elsif items.one?
        items.first
      end
      item || raise(Refused, "#{@agent.name}'s plan isn't on its subscription any more. Try again in a minute.")
    end

    # Tests stand in a sync that fails after the remote change.
    def sync_class = SubscriptionSync

  end
end
