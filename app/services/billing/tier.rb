# The server-owned plan catalogue. A Stripe price that isn't here is refused.
# Allowance and container numbers are placeholders until calibrated against
# per-resident cost (design doc, "What a tier controls").
module Billing
  class Tier

    attr_reader :id, :name, :monthly_usd, :allowance_usd, :memory_gb, :cpu_shares

    def initialize(id:, name:, monthly_usd:, allowance_usd:, memory_gb:, cpu_shares:)
      @id = id
      @name = name
      @monthly_usd = monthly_usd
      @allowance_usd = allowance_usd
      @memory_gb = memory_gb
      @cpu_shares = cpu_shares
    end

    CATALOGUE = [
      new(id: "starter", name: "Starter", monthly_usd: 20, allowance_usd: 8, memory_gb: 4, cpu_shares: 1024),
      new(id: "studio", name: "Studio", monthly_usd: 50, allowance_usd: 25, memory_gb: 8, cpu_shares: 2048)
    ].freeze

    def self.all = CATALOGUE

    def self.find(id)
      CATALOGUE.find { |tier| tier.id == id.to_s }
    end

    def self.find!(id)
      find(id) || raise(ArgumentError, "Unknown plan #{id.inspect}")
    end

    def self.for_price(price_id)
      return nil if price_id.blank?

      CATALOGUE.find { |tier| tier.price_id == price_id }
    end

    # Stripe price IDs differ between test and live mode, so they are configuration.
    def price_id
      Rails.application.credentials.dig(:stripe, :prices, id.to_sym).presence ||
        ENV["STRIPE_PRICE_#{id.upcase}"].presence
    end

    def purchasable? = price_id.present?

    def as_json(*)
      {
        id: id, name: name, monthly_usd: monthly_usd, allowance_usd: allowance_usd,
        memory_gb: memory_gb, purchasable: purchasable?
      }
    end

  end
end
