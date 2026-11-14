# What an account is being charged for each month, from the house's own
# records: its plan, if it pays for one, and each resident with a live
# subscription row, at the Stripe price that row was sold at. Nothing here
# asks Stripe anything.
#
# This is the first piece of "the house owns the bill"
# (docs/proposals/2026-11-14-one-bill.md). Stripe allows a price once per
# subscription, so the bill is one line per price with a quantity: two
# residents sold at the same price are one line of two. The price is the one
# recorded at the sale, never the offer's current one, so a resident on a
# retired price keeps it (#619). A row with no recorded price, or one that is
# not its offer's or its plan's, is refused: missing evidence never picks a
# price.
#
# It follows the charge, not the entitlement: a resident whose grace ran out
# is held, yet stays on the bill for as long as its subscription is live,
# because Stripe is still asking for that money. So this is a reading of what
# is charged. It is not a statement of what the account wants to pay, and
# nothing may shrink a subscription to match it; a change to the bill is its
# own confirmed act.
#
# Read only.
module Billing
  class Bill

    Line = Data.define(:kind, :id, :name, :price_id, :quantity, :unit_usd) do
      def total_usd = unit_usd && (unit_usd * quantity)

      def as_json(*)
        { kind:, id:, name:, price_id:, quantity:, unit_usd: unit_usd && Billing.usd(unit_usd),
          total_usd: total_usd && Billing.usd(total_usd) }
      end
    end

    # A row whose recorded price is missing or not one of its offer's or plan's.
    class UnknownPrice < StandardError; end

    def initialize(account)
      @account = account
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
      return nil unless subscription

      plan = subscription.plan_record
      price = recorded!(subscription.stripe_price_id, plan.price_ids, "The #{plan.name} plan")
      line("plan", plan.id, plan.name, price, 1, plan.price_id, plan.monthly_usd)
    end

    def resident_lines
      sold = ResidentSubscription.live.where(account: @account).group_by do |subscription|
        offer = subscription.offer
        [ offer, recorded!(subscription.stripe_price_id, offer.price_ids, "Resident #{subscription.agent_id}") ]
      end
      sold.sort_by { |(offer, price), _| sort_key(offer, price) }.map do |(offer, price), subscriptions|
        line("resident", offer.id, offer.name, price, subscriptions.size, offer.price_id, offer.monthly_usd)
      end
    end

    def recorded!(price, known, whose)
      return price if price.present? && known.include?(price)

      raise UnknownPrice, "#{whose} is recorded at price #{price.inspect}, which is not one of its own"
    end

    def line(kind, id, name, price, quantity, current_price, monthly_usd)
      Line.new(kind:, id:, name:, price_id: price, quantity:, unit_usd: price == current_price ? monthly_usd : nil)
    end

    def sort_key(offer, price)
      [ Tier.all.index(offer.tier), Tier::RATES.index(offer.rate), offer.price_ids.index(price) ]
    end

  end
end
