# One way a plan can be bought: a tier (the machine and what comes with it)
# at a rate (what it costs and what house-model allowance it includes). The
# standard rate is the plan as published. At cost is the plan at the price of
# its machine and what the machine drags with it, with no allowance: an
# at-cost resident brings its own model (jBVrDj, 2026-10-28;
# docs/proposals/2026-10-28-billing-codes-at-cost.md). A Stripe price
# resolves to exactly one offer.
module Billing
  Offer = Data.define(:tier, :rate) do
    def self.for_price(price_id)
      return nil if price_id.blank?

      Tier.all.each do |tier|
        Tier::RATES.each do |rate|
          offer = new(tier:, rate:)
          return offer if offer.price_ids.include?(price_id)
        end
      end
      nil
    end

    def standard? = rate == "standard"
    def at_cost? = rate == "at_cost"

    # The key under which the offer's Stripe prices are configured.
    def id = standard? ? tier.id : "#{tier.id}_#{rate}"
    def name = standard? ? tier.name : "#{tier.name} at cost"
    def monthly_usd = standard? ? tier.monthly_usd : Tier::AT_COST_MONTHLY_USD.fetch(tier.id)
    def allowance_usd = standard? ? tier.allowance_usd : 0

    # Stripe price ids differ between test and live mode, so they are
    # configuration. An offer may have several, current first: re-costing
    # makes a new Stripe price, and the subscriptions still on the old one
    # must keep syncing (#619), so a retired id is recognised but never sold.
    # Credentials: stripe.prices.<offer id> as one id or a list; ENV
    # STRIPE_PRICE_<OFFER ID> comma-separated.
    def price_ids
      configured = Rails.application.credentials.dig(:stripe, :prices, id.to_sym).presence ||
        ENV["STRIPE_PRICE_#{id.upcase}"].presence
      Array(configured).flat_map { |value| value.to_s.split(",") }.map(&:strip).reject(&:blank?)
    end

    # What a new purchase buys.
    def price_id = price_ids.first

    def purchasable? = price_id.present?

    def as_json(*)
      { id: id, tier: tier.id, rate: rate, name: name, monthly_usd: monthly_usd, allowance_usd: allowance_usd,
        purchasable: purchasable? }
    end
  end
end
