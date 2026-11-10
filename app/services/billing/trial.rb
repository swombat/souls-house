# The free trial (2026-11-10): a small resident (tier "conversation", standard
# rate) for TRIAL_DAYS without a card, bought through Stripe Checkout with
# subscription_data.trial_period_days and payment_method_collection
# "if_required". With no card at the end Stripe cancels the subscription and
# the ordinary ended-subscription path puts the resident to sleep, deleting
# nothing; with a card (added in Stripe's portal) it becomes active and nothing
# else changes. While it is trialing the account's house-model allowance is
# $10 for the whole trial, not $10 a month (ResidentEntitlement#allowance_limit).
#
# Once per account, ever. Offered to an account that pays per resident, has
# never had a trial and has never had a ResidentSubscription, while Site
# Admin's free_trial_enabled is on. How a second trial is made impossible:
#
#   1. claim!: a single conditional UPDATE sets accounts.trial_started_at only
#      while it is NULL, in the same transaction that inserts the trial order.
#      Two wizard tabs or a replayed request: one UPDATE matches, the other
#      matches nothing and is refused.
#   2. A partial unique index allows one trial order per account that is
#      pending, born or failed: the backstop if the claim were ever released
#      under a racing claim.
#   3. The order's Checkout session is created under an idempotency key per
#      order from a pinned payload, so a replay returns the same session; a
#      session yields one subscription, and a born order is never born again
#      (PaidBirth's order lock), so replayed webhooks complete one birth.
#
# The claim is given back only when its order is abandoned with its Checkout
# session confirmed expired (Stripe says no subscription was or can be made):
# a trial that never started isn't spent.
module Billing
  module Trial

    DAYS = 14
    TIER = "conversation".freeze
    RATE = "standard".freeze
    HOLDING_STATES = %w[pending born failed].freeze
    SPENT = "This account has already had its free trial. Choose a plan to create the resident.".freeze

    module_function

    def offer = Tier.find!(TIER).offer(RATE)

    # Whether the account would be offered the trial now.
    def eligible?(account) = offered?(account) && unspent?(account)

    # Whether the house offers the trial to this kind of account at all.
    def offered?(account)
      return false unless account&.billing_required?
      return false unless Setting.instance.free_trial_enabled?

      Billing.configured? && offer.purchasable?
    end

    def unspent?(account)
      account.trial_started_at.nil? && !ResidentSubscription.exists?(account_id: account.id) &&
        !ResidentBirthOrder.where(account_id: account.id, trial: true, state: HOLDING_STATES).exists?
    end

    # Claims the account's one trial and yields inside the same transaction,
    # where the caller inserts the trial order; anything raised rolls the
    # claim back. Raises PaidBirth::Refused if it is spent or not offered.
    def claim!(account, now: Time.current)
      raise PaidBirth::Refused, "The free trial isn't offered here." unless offered?(account)

      ApplicationRecord.transaction do
        claimed = Account.where(id: account.id, trial_started_at: nil).update_all(trial_started_at: now, updated_at: now)
        raise PaidBirth::Refused, SPENT unless claimed == 1
        if ResidentSubscription.exists?(account_id: account.id) ||
           ResidentBirthOrder.where(account_id: account.id, trial: true, state: HOLDING_STATES).exists?
          raise PaidBirth::Refused, SPENT
        end

        account.trial_started_at = now
        yield
      end
    rescue ActiveRecord::RecordNotUnique
      account.trial_started_at = nil
      raise PaidBirth::Refused, SPENT
    end

    # Gives the claim back after its order was abandoned without a
    # subscription, unless another trial order holds it.
    def release!(order)
      return unless order.trial? && order.abandoned?

      Account.where(id: order.account_id)
        .where.not(id: ResidentBirthOrder.where(trial: true, state: HOLDING_STATES).select(:account_id))
        .where.not(id: ResidentSubscription.select(:account_id))
        .update_all(trial_started_at: nil, updated_at: Time.current)
    end

    # When the account's allowance is a trial's: every resident drawing on it
    # (ResidentEntitlement.on_account_allowance) is on a trialing
    # subscription. A held resident draws nothing, so it doesn't count either
    # way. Returns when the trial began, or nil.
    #
    # With nobody in force, the only calls still funded are a held resident's
    # unfinished turn (ResidentEntitlement#draining?). If the account has
    # never paid for a standard-rate resident, that turn is the trial's and
    # keeps the trial's ceiling: a trial cancelled mid-turn must not find a
    # fresh month's $10.
    def allowance_started_at(account_id)
      drawing = ResidentSubscription.where(
        id: ResidentEntitlement.where(account_id: account_id).on_account_allowance.select(:current_subscription_id)
      )
      statuses = drawing.distinct.pluck(:stripe_status)
      return nil unless statuses == [ "trialing" ] || (statuses.empty? && never_paid?(account_id))

      Account.where(id: account_id).pick(:trial_started_at) || drawing.minimum(:created_at)
    end

    # No standard-rate subscription of the account has had a paid period:
    # each one's current period still ends with its trial. A subscription
    # with no trial on record counts as paid.
    def never_paid?(account_id)
      subscriptions = ResidentSubscription.where(account_id: account_id, rate: "standard")
      subscriptions.exists? &&
        subscriptions.where("trial_end IS NULL OR current_period_end IS NULL OR current_period_end > trial_end").none?
    end

    # The trial's props for the wizard and the Billing tab.
    def as_json_for(account) = { eligible: eligible?(account), days: DAYS }

  end
end
