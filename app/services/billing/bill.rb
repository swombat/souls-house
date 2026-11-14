# What an account should be paying each month, from the house's own records:
# its plan, if it pays for one, and each resident it pays for, at the Stripe
# price that resident was sold at. Nothing here asks Stripe anything.
#
# This is the first piece of "the house owns the bill"
# (docs/proposals/2026-11-14-one-bill.md). Stripe allows a price once per
# subscription, so the bill is one line per price with a quantity: two
# residents sold at the same price are one line of two. The price is the one
# recorded at the sale, not the offer's current one, so a resident on a
# retired price keeps it (#619).
#
# Read only. Nothing changes a subscription from it yet.
module Billing
  class Bill

    Line = Data.define(:kind, :id, :name, :price_id, :quantity, :unit_usd) do
      def total_usd = unit_usd && (unit_usd * quantity)

      def as_json(*)
        { kind:, id:, name:, price_id:, quantity:, unit_usd: unit_usd && Billing.usd(unit_usd),
          total_usd: total_usd && Billing.usd(total_usd) }
      end
    end

    # A paid resident whose recorded price is not one of its offer's.
    class UnknownPrice < StandardError; end

    def initialize(account, now: Time.current)
      @account = account
      @now = now
    end

    # The plan first, then residents from small to large, standard before at
    # cost, current prices before retired ones.
    def lines = @lines ||= [ plan_line, *resident_lines ].compact

    # What the account's one Stripe subscription should carry.
    def items = lines.map { |line| { price: line.price_id, quantity: line.quantity } }

    def empty? = lines.empty?

    # Nil when a line is on a retired price: the house keeps the id of a
    # retired price, never its amount. Stripe has it.
    def total_usd
      lines.all?(&:unit_usd) ? lines.sum(BigDecimal("0"), &:total_usd) : nil
    end

    def as_json(*) = { lines: lines.map(&:as_json), total_usd: total_usd && Billing.usd(total_usd) }

    private

    def plan_line
      subscription = @account.live_plan_subscription
      return nil unless subscription&.in_force?(@now)

      plan = subscription.plan_record
      line("plan", plan.id, plan.name, subscription.stripe_price_id.presence || plan.price_id, 1, plan.price_id,
        plan.monthly_usd)
    end

    def resident_lines
      sold = paid_subscriptions.group_by { |subscription| [ subscription.offer, price_of(subscription) ] }
      sold.sort_by { |(offer, price), _| sort_key(offer, price) }.map do |(offer, price), subscriptions|
        line("resident", offer.id, offer.name, price, subscriptions.size, offer.price_id, offer.monthly_usd)
      end
    end

    # The subscriptions of residents whose paid plan is in force.
    def paid_subscriptions
      ResidentEntitlement.where(account: @account, source: "stripe", state: %w[active grace])
        .includes(:current_subscription).filter_map(&:current_subscription).select(&:live?)
    end

    def price_of(subscription)
      price = subscription.stripe_price_id.presence || subscription.offer.price_id
      return price if subscription.offer.price_ids.include?(price)

      raise UnknownPrice, "Resident #{subscription.agent_id} is recorded at price #{price.inspect}, " \
        "which is not one of #{subscription.offer.name}'s"
    end

    def line(kind, id, name, price, quantity, current_price, monthly_usd)
      Line.new(kind:, id:, name:, price_id: price, quantity:, unit_usd: price == current_price ? monthly_usd : nil)
    end

    def sort_key(offer, price)
      [ Tier.all.index(offer.tier), Tier::RATES.index(offer.rate), offer.price_ids.index(price) ]
    end

  end
end
