# Reads Stripe's Customer Portal configurations and says which prices a
# customer could switch a subscription to there. At-cost prices must never be
# among them (docs/proposals/2026-10-28-billing-codes-at-cost.md): a comment
# can't enforce that; a read of the live configuration, shown in Site Admin,
# can. Cached for an hour. A Stripe error is reported as an error, never as
# "nothing is switchable".
module Billing
  class PortalCheck

    TTL = 1.hour
    CACHE_KEY = "billing/portal_check".freeze

    def self.call(client: nil, now: Time.current, fresh: false)
      Rails.cache.fetch(CACHE_KEY, expires_in: TTL, force: fresh) { new(client: client || Billing.client).read(now) }
    end

    def initialize(client:)
      @client = client
    end

    def read(now = Time.current)
      switchable = []
      @client.v1.billing_portal.configurations.list({ limit: 100 }).data.each do |configuration|
        next unless configuration.active

        update = configuration.features.subscription_update
        next unless update && update.enabled

        Array(update.products).each { |product| switchable.concat(Array(product.prices).map(&:to_s)) }
      end
      at_cost = Tier.all.flat_map { |tier| tier.offer("at_cost").price_ids }
      { checked_at: now.iso8601, switchable_prices: switchable.uniq, at_cost_switchable: switchable.uniq & at_cost }
    rescue Stripe::StripeError => error
      { checked_at: now.iso8601, error: error.message }
    end

  end
end
