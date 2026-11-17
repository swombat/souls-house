# The plan's own resident (Daniel, jaMWBj jRyMoO 2026-11-13: "you're paying
# for the companion plan and you get a free resident"). An account that pays
# for a plan, or is given one, has one resident at the included rate: its
# size less a Small (Billing::Offer#monthly_usd), so a Small is free and a
# bigger one costs the difference. Every further resident is at its size.
#
# The buyer never chooses the included rate: they buy a size at the catalogue
# price and this decides which rate the line is sold at. One rule: a
# catalogue purchase is the included resident when the account has a plan to
# include it and no included resident yet, live or waiting to be born. An
# account has a plan to include it when its first bill is being opened (the
# plan comes on that bill too), when its bill already carries a plan line, or
# when it is given a plan (a free account). An account holding an at-cost
# code never has one ("an at-cost residence, no free residence", YkMbQn).
# A bill with no plan line and no plan given stays as it is: each resident
# at its size, as before the plan included its resident.
module Billing
  module Included

    module_function

    # The offer a catalogue purchase of this size is sold at on this account.
    # At-cost offers pass through unchanged.
    def offer_for(account, offer, except_agent: nil, except_order: nil)
      return offer unless offer.catalogue?

      offer.tier.offer(available?(account, except_agent:, except_order:) ? "included" : "standard")
    end

    # Whether the account's next catalogue purchase would be its included
    # resident.
    def available?(account, except_agent: nil, except_order: nil)
      return false if account.at_cost_holder?
      return false unless account.given_plan || account.account_subscriptions.live.exists? ||
        !Reconcile.applies?(account)

      held = ResidentSubscription.live.where(account:, rate: "included")
      held = held.where.not(agent_id: except_agent) if except_agent
      return false if held.exists?

      waiting = ResidentBirthOrder.pending.where(account:, rate: "included")
      waiting = waiting.where.not(id: except_order.id) if except_order
      !waiting.exists?
    end

    # The resident that becomes the included one when the included resident
    # leaves a bill: the oldest standard-rate resident left on it. Nil when
    # there is none, and then the plan leaves with it.
    def successor(stripe_subscription_id, leaving_agent_id)
      ResidentSubscription.live.where(stripe_subscription_id:, rate: "standard")
        .where.not(agent_id: leaving_agent_id).order(:created_at, :id).first
    end

  end
end
