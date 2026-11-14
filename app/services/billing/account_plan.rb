# What an account can do, paid for separately from its residents (each
# resident is paid for by its size, Billing::Tier). Ordered: companions <
# partners < colleagues; Account#plan is the higher of a site admin's grant
# and a paid AccountSubscription, companions by default.
#
# Companions is free on top of the residents and has no Stripe price and no
# subscription. Public cards lead with from_usd (the add-on plus one small
# resident), never with Companions' $0 add-on.
#
# Transcription hours and backup space are the account's, one pool however
# many residents it has (Daniel, jaMWBj 2026-11-13). They carry across the
# ladder the sizes had (Small's, Medium's, Large's). Nothing meters or stops
# them yet, so they are not in features and not shown: a number nobody
# enforces is not an allowance (ePoEyY). They are here for costing until the
# hard stops ship.
module Billing
  class AccountPlan

    IDS = %w[companions partners colleagues].freeze
    DEFAULT_ID = "companions".freeze

    attr_reader :id, :name, :monthly_usd, :members, :swarm_searches, :transcription_hours, :backup_gb

    def initialize(id:, name:, monthly_usd:, members:, swarm_searches:, subagents:, transcription_hours:, backup_gb:)
      @id = id
      @name = name
      @monthly_usd = BigDecimal(monthly_usd)
      @members = members
      @swarm_searches = swarm_searches
      @subagents = subagents
      @transcription_hours = transcription_hours
      @backup_gb = backup_gb
    end

    CATALOGUE = [
      new(id: "companions", name: "Companions", monthly_usd: "0", members: "one", swarm_searches: 0, subagents: false,
        transcription_hours: 5, backup_gb: 10),
      new(id: "partners", name: "Partners", monthly_usd: "20", members: "several", swarm_searches: 20, subagents: false,
        transcription_hours: 20, backup_gb: 50),
      new(id: "colleagues", name: "Colleagues", monthly_usd: "50", members: "several", swarm_searches: 100,
        subagents: true, transcription_hours: 40, backup_gb: 200)
    ].freeze

    def self.all = CATALOGUE

    def self.default = find!(DEFAULT_ID)

    def self.find(id)
      CATALOGUE.find { |plan| plan.id == id.to_s }
    end

    def self.find!(id)
      find(id) || raise(ArgumentError, "Unknown account plan #{id.inspect}")
    end

    def self.for_price(price_id)
      return nil if price_id.blank?

      CATALOGUE.find { |plan| plan.price_ids.include?(price_id) }
    end

    # The highest of the plans given (ids or plans, nils ignored); the
    # default when none.
    def self.highest(*plans)
      plans.flatten.compact.map { |plan| plan.is_a?(self) ? plan : find(plan) }.compact.max || default
    end

    include Comparable

    def <=>(other) = rank <=> other.rank

    def rank = IDS.index(id)

    def several_members? = members == "several"
    def subagents? = @subagents
    def swarm_search? = swarm_searches.positive?
    def free? = monthly_usd.zero?

    # The add-on and one small resident: what an account on this plan pays
    # at least.
    def from_usd = monthly_usd + Tier.find!("conversation").monthly_usd

    # Same list semantics as Billing::Offer#price_ids: current first, retired
    # ids recognised but never sold. Credentials stripe.prices.account_<id>
    # as one id or a list; ENV STRIPE_PRICE_ACCOUNT_<ID> comma-separated.
    # Companions has none.
    def price_ids
      return [] if free?

      key = "account_#{id}"
      configured = Rails.application.credentials.dig(:stripe, :prices, key.to_sym).presence ||
        ENV["STRIPE_PRICE_#{key.upcase}"].presence
      Array(configured).flat_map { |value| value.to_s.split(",") }.map(&:strip).reject(&:blank?)
    end

    def price_id = price_ids.first

    def purchasable? = price_id.present?

    def features
      { members: members, swarm_searches: swarm_searches, subagents: subagents? }
    end

    def as_json(*)
      { id: id, name: name, monthly_usd: Billing.usd(monthly_usd), from_usd: Billing.usd(from_usd),
        purchasable: purchasable?, features: features }
    end

  end
end
