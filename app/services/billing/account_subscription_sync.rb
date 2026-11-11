# Brings one Stripe subscription for an account's plan into the house
# (metadata kind=account_plan, Billing::AccountPlanCheckout). Like
# SubscriptionSync it never trusts the event's copy: it re-fetches under a
# per-account advisory lock of its own, validates the account, the customer
# and the price against Billing::AccountPlan, and records it.
#
# It touches nothing but the AccountSubscription: the plan's features follow
# from Account#plan, and no resident is slept or woken by it. A resident's
# subscription never touches this one either.
module Billing
  class AccountSubscriptionSync

    KIND = "account_plan".freeze
    LOCK_NAMESPACE = 7_242_003 # per account, for the account plan only

    def initialize(stripe_subscription_id, client: Billing.client, now: Time.current)
      @stripe_subscription_id = stripe_subscription_id
      @client = client
      @now = now
    end

    def call
      account = account_for(fetch)

      ApplicationRecord.transaction do
        ApplicationRecord.connection.execute("SELECT pg_advisory_xact_lock(#{LOCK_NAMESPACE}, #{Integer(account.id)})")
        remote = fetch
        plan = validate!(remote, account)
        record!(remote, account, plan)
      end
    end

    private

    def fetch
      @client.v1.subscriptions.retrieve(@stripe_subscription_id)
    end

    def account_for(remote)
      account_id = remote.metadata && remote.metadata["account_id"]
      Account.find_by(id: account_id) ||
        raise(InvalidSubscription, "Subscription #{@stripe_subscription_id} names no account here (#{account_id.inspect})")
    end

    def validate!(remote, account)
      if remote.metadata["kind"] != KIND || remote.metadata["account_id"].to_s != account.id.to_s
        raise InvalidSubscription, "Subscription #{@stripe_subscription_id} changed account"
      end

      customer = BillingCustomer.find_by(account: account)
      if customer.nil? || customer.stripe_customer_id != stripe_id(remote.customer)
        raise InvalidSubscription, "Subscription #{@stripe_subscription_id} belongs to another customer"
      end

      items = remote.items.data
      plan = items.one? && AccountPlan.for_price(stripe_id(items.first.price))
      plan || raise(InvalidSubscription, "Subscription #{@stripe_subscription_id} has a price outside the account plans")
    end

    def record!(remote, account, plan)
      subscription = AccountSubscription.find_or_initialize_by(stripe_subscription_id: remote.id)
      if subscription.new_record? && remote.status.in?(AccountSubscription::LIVE_STATUSES) &&
          account.account_subscriptions.live.where.not(stripe_subscription_id: remote.id).exists?
        # A second live plan for one account: Checkout refuses this, so it
        # is a mistake made at Stripe. Refused (and reported by the event
        # job) for an operator to refund; the index is the backstop.
        raise InvalidSubscription, "Account #{account.id} already has a live plan; #{remote.id} is a second one"
      end
      subscription.assign_attributes(
        account: account,
        plan: plan.id,
        stripe_price_id: stripe_id(remote.items.data.first.price),
        stripe_status: remote.status,
        current_period_end: period_end(remote),
        cancel_at_period_end: remote.cancel_at_period_end ? true : false,
        last_synced_at: @now
      )
      if remote.status == "past_due"
        subscription.past_due_since ||= @now
      else
        subscription.past_due_since = nil
      end
      subscription.save!
      subscription
    end

    # Newer Stripe API versions keep the period on the subscription item.
    def period_end(remote)
      seconds = remote.items.data.first&.[](:current_period_end) || remote[:current_period_end]
      seconds && Time.zone.at(seconds)
    end

    def stripe_id(value) = value.respond_to?(:id) ? value.id : value

  end
end
