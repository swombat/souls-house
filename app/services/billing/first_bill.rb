module Billing
  # One first bill per account. A first bill is opened by a paid creation
  # (PaidBirth#start!), the free trial (PaidBirth#start_trial!), a Checkout
  # for a resident already in the account (Checkout#url) or a Checkout for
  # the account's plan alone (PlanCheckout#url). Each holds the
  # account's billing lock; this is what each asks under it, so whichever
  # comes second sees the first and waits, rather than opening a second
  # subscription beside it (Build C, A's leftover).
  module FirstBill

    WAITING = "Someone in this account has already started its first bill, and it hasn't gone through yet. " \
              "Once it has, start this resident again and it goes onto that bill. If it doesn't go through, " \
              "this is freed once Stripe has closed it; if that takes more than a day, contact " \
              "#{Billing.contact_email}.".freeze

    module_function

    # First-bill orders born (paid, resident made) whose subscription the
    # house never linked: BillSync failed after the birth committed. Their
    # bill is real but Reconcile.applies? can't see it (Mira, #1024).
    def unlinked(account)
      ResidentBirthOrder.where(account:, state: "born").where.not(kind: "item").where.not(stripe_subscription_id: nil)
        .where.not(stripe_subscription_id: ResidentSubscription.select(:stripe_subscription_id))
    end

    # Under the account's lock: link what can be linked now, so the bill is
    # seen and the next resident goes onto it. What still can't be linked
    # stays in unlinked and refuses a new first bill (waiting?).
    def relink!(account, client:)
      unlinked(account).find_each do |order|
        BillSync.new(order.stripe_subscription_id, client:).call
      rescue StandardError => error
        Rails.error.report(error, handled: true, context: { subsystem: "billing", birth_order_id: order.id })
      end
    end

    # A first bill waiting that isn't the caller's own to settle or replace:
    # another person's creation or trial still pending, or paid and not yet
    # born (failed); anyone's first bill born and not yet linked (relink!
    # first); a Checkout open for another resident; or a Checkout for the
    # plan not yet paid, expired or settled, including one whose create had
    # no answer (except for PlanCheckout itself, which recovers or replaces
    # its own). Call after Checkout.release_expired!, so a Checkout that has
    # run out doesn't count.
    def waiting?(account, except_creator: nil, except_agent: nil, except_plan_checkout: false)
      orders = ResidentBirthOrder.where(account:, state: %w[pending failed]).where.not(kind: "item")
      orders = orders.where.not(creator: except_creator) if except_creator
      attempts = BillingCheckoutAttempt.unresolved.where(account:, kind: "checkout")
      attempts = attempts.where.not(agent: except_agent) if except_agent
      plan = !except_plan_checkout && AccountPlanCheckoutAttempt.unresolved.exists?(account:)
      orders.exists? || unlinked(account).exists? || attempts.exists? || plan
    end

    def refuse_if_waiting!(account, error:, **except)
      raise error, WAITING if waiting?(account, **except)
    end

  end
end
