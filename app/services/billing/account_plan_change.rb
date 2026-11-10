# Moves an account's paid plan between Partners and Colleagues: a Stripe
# subscription item price change, prorated by Stripe for the rest of the
# period, then brought in through AccountSubscriptionSync so Account#plan
# follows at once. Dropping to Companions is cancelling, done in Stripe's
# portal.
module Billing
  class AccountPlanChange

    class Refused < StandardError; end

    def initialize(account:, plan:, client: Billing.client)
      @account = account
      @plan = plan
      @client = client
    end

    # Returns the synced AccountSubscription on the new plan.
    #
    # In Billing::PlanChange's three steps, so nothing Stripe has done can be
    # undone locally:
    #  0. Bring in what Stripe has now, committed: a change whose answer was
    #     lost has already happened there.
    #  1. Under AccountSubscriptionSync's per-account lock: decide, and give
    #     the change its own identity (the subscription's change count),
    #     committed before Stripe is called.
    #  2. The Stripe update under that key. Setting a price Stripe already has
    #     changes nothing, so a change performed twice is harmless; one
    #     replayed instead of performed is not.
    #  3. AccountSubscriptionSync, whose answer is what Stripe has.
    def call
      raise Refused, "To move to Companions, cancel the plan from Manage billing." if @plan.free?

      current = @account.live_plan_subscription
      refuse_unless_paid!(current)
      sync_class.new(current.stripe_subscription_id, client: @client).call

      remote_id, item_id, from, count = ApplicationRecord.transaction do
        ApplicationRecord.connection.execute(
          "SELECT pg_advisory_xact_lock(#{AccountSubscriptionSync::LOCK_NAMESPACE}, #{Integer(@account.id)})"
        )
        subscription = @account.live_plan_subscription
        refuse_unless_paid!(subscription)
        raise Refused, "This account is already on #{@plan.name}." if subscription.plan == @plan.id
        raise NotConfigured, "The #{@plan.name} plan has no Stripe price configured" unless @plan.purchasable?

        remote = @client.v1.subscriptions.retrieve(subscription.stripe_subscription_id)
        item = remote.items.data.first
        from = item.price.respond_to?(:id) ? item.price.id : item.price
        subscription.update!(plan_changes_count: subscription.plan_changes_count + 1)
        [ remote.id, item.id, from, subscription.plan_changes_count ]
      end

      @client.v1.subscriptions.update(remote_id, {
        items: [ { id: item_id, price: @plan.price_id } ],
        proration_behavior: "create_prorations",
        description: "#{@plan.name} plan for #{@account.name}",
        metadata: { plan: @plan.id }
      }, { idempotency_key: "souls-house-account-plan-change-#{remote_id}-#{count}-#{from}-#{@plan.price_id}" })
      sync_class.new(remote_id, client: @client).call
    end

    private

    def refuse_unless_paid!(subscription)
      return if subscription&.live? && subscription.in_force?

      raise Refused, "This account has no paid plan to change. Choose a plan first."
    end

    # Tests stand in a sync that fails after the remote change.
    def sync_class = AccountSubscriptionSync

  end
end
