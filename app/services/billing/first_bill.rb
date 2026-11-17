module Billing
  # One first bill per account. A first bill is opened by a paid creation
  # (PaidBirth#start!), the free trial (PaidBirth#start_trial!) or a Checkout
  # for a resident already in the account (Checkout#url). Each holds the
  # account's billing lock; this is what each asks under it, so whichever
  # comes second sees the first and waits, rather than opening a second
  # subscription beside it (Build C, A's leftover).
  module FirstBill

    WAITING = "Someone in this account has already started its first bill, and it hasn't gone through yet. " \
              "Once it has, start this resident again and it goes onto that bill. If it doesn't go through, " \
              "it lapses within a day.".freeze

    module_function

    # A first bill waiting that isn't the caller's own to settle or replace:
    # another person's creation or trial still pending, or paid and not yet
    # born (failed); or a Checkout open for another resident. Call after
    # Checkout.release_expired!, so a Checkout that has run out doesn't count.
    def waiting?(account, except_creator: nil, except_agent: nil)
      orders = ResidentBirthOrder.where(account:, state: %w[pending failed]).where.not(kind: "item")
      orders = orders.where.not(creator: except_creator) if except_creator
      attempts = BillingCheckoutAttempt.unresolved.where(account:, kind: "checkout")
      attempts = attempts.where.not(agent: except_agent) if except_agent
      orders.exists? || attempts.exists?
    end

    def refuse_if_waiting!(account, error:, **except)
      raise error, WAITING if waiting?(account, **except)
    end

  end
end
