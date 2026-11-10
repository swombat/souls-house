# The server-owned catalogue of resident sizes. A Stripe price that isn't
# here is refused. Every resident is paid for by its size; what the account
# can do (members, swarm searches, sub-agents) is its plan, a separate charge
# (Billing::AccountPlan). The ids are the original plan names and stay: they
# are in the database, Stripe metadata and the credentials keys. People see
# the size: Small, Medium, Large (2026-11-10).
#
# Each plan's numbers were costed against what the house pays at full use
# (Lume's table in WjNvXj/YwkgkY, 2026-10-14; Daniel agreed): the Hetzner
# machine, the house-model allowance, Scribe transcription at $0.22/h, Restic
# backups at S3 list price, swarm reads and Stripe's fee. Every plan keeps a
# positive margin even when someone uses all of it. Change a number here and
# re-cost it. The house-model allowance is no longer a resident's: it is $10
# a month per account, shared by its standard-rate residents
# (ResidentEntitlement#allowance_limit). allowance_usd here is that account
# allowance, which a standard-rate resident of any size draws on.
#
# memory_gb and cpu_shares are the container limits while residents still live
# on the shared house server; the machine is what a plan gets once hosting moves
# to one VM per resident.
module Billing
  class Tier

    MACHINES = {
      "cx23" => { vcpus: 2, ram_gb: 4, disk_gb: 40 },
      "cx33" => { vcpus: 4, ram_gb: 8, disk_gb: 80 },
      "cx43" => { vcpus: 8, ram_gb: 16, disk_gb: 160 }
    }.freeze

    # Outside services a resident on the plan may be connected to. Named by
    # relationship (Daniel, WjNvXj 2026-10-14): Conversation talks with you,
    # Life helps run your life, Work does serious work beside you. A plan with
    # no connections is conversation only. These say what a plan WILL grant
    # once plans open; nothing enforces them until checkout is gated on it.
    CONNECTIONS = %w[google_workspace telegram whatsapp x github dns].freeze

    # The rates a tier can be bought at (Billing::Offer).
    RATES = %w[standard at_cost].freeze

    # At cost, per tier, in USD a month (Daniel, jBVrDj 2026-10-28): the
    # machine and what it drags with it, rounded up to the dollar. Costed
    # against net Hetzner list price (reverse charge) at ECB 1.115 USD/EUR,
    # the primary IPv4 and Stripe's UK fee on an EU card; the test holds the
    # working. No house-model allowance. Re-cost by hand when Hetzner or the
    # exchange rate moves: that makes a new Stripe price, and the old id
    # stays in the list (#619).
    AT_COST_MONTHLY_USD = { "conversation" => BigDecimal("8"), "life" => BigDecimal("11"), "work" => BigDecimal("20") }.freeze

    # The house-model allowance, per account per UTC month, shared by every
    # resident whose plan funds calls at the standard rate.
    ACCOUNT_ALLOWANCE_USD = BigDecimal("10")

    SIZES = %w[small medium large].freeze

    attr_reader :id, :name, :size, :monthly_usd, :allowance_usd, :memory_gb, :cpu_shares, :server_type,
      :transcription_hours, :backup_gb, :swarm_searches, :connections

    def initialize(id:, name:, size:, monthly_usd:, memory_gb:, cpu_shares:, server_type:,
      transcription_hours:, backup_gb:, swarm_searches: 0, connections: [])
      @id = id
      @name = name
      @size = size
      @monthly_usd = BigDecimal(monthly_usd)
      @allowance_usd = ACCOUNT_ALLOWANCE_USD
      @memory_gb = memory_gb
      @cpu_shares = cpu_shares
      @server_type = server_type
      @transcription_hours = transcription_hours
      @backup_gb = backup_gb
      @swarm_searches = swarm_searches
      @connections = connections
    end

    # swarm_searches stay for costing what a size used to include; the
    # account's searches come from its plan (Billing::AccountPlan), not here.
    CATALOGUE = [
      new(id: "conversation", name: "Small", size: "small", monthly_usd: "9.99", memory_gb: 4, cpu_shares: 1024,
        server_type: "cx23", transcription_hours: 5, backup_gb: 10),
      new(id: "life", name: "Medium", size: "medium", monthly_usd: "19.99", memory_gb: 8, cpu_shares: 2048,
        server_type: "cx33", transcription_hours: 20, backup_gb: 50, swarm_searches: 20, connections: CONNECTIONS),
      new(id: "work", name: "Large", size: "large", monthly_usd: "49.99", memory_gb: 16, cpu_shares: 4096,
        server_type: "cx43", transcription_hours: 40, backup_gb: 200, swarm_searches: 100,
        connections: CONNECTIONS)
    ].freeze

    # Entitlement states in which a resident's plan is in force.
    IN_FORCE_STATES = %w[active grace complimentary].freeze

    def self.all = CATALOGUE

    def self.find(id)
      CATALOGUE.find { |tier| tier.id == id.to_s }
    end

    def self.find!(id)
      find(id) || raise(ArgumentError, "Unknown plan #{id.inspect}")
    end

    def self.for_price(price_id)
      Offer.for_price(price_id)&.tier
    end

    def offer(rate = "standard") = Offer.new(tier: self, rate: rate.to_s)

    def offers = RATES.map { |rate| offer(rate) }

    # The standard offer's prices; see Billing::Offer.
    def price_ids = offer.price_ids
    def price_id = offer.price_id
    def purchasable? = price_id.present?

    def machine = MACHINES.fetch(server_type)

    # What the size includes, for the public page, the Billing tab, the
    # creation wizard and the about-sheet. Only what a size delivers today:
    # hosting for one resident, and the account's house-model allowance it
    # draws on, shared with the account's other standard-rate residents
    # (allowance_usd). Swarm searches and sub-agents are the account plan's
    # (Billing::AccountPlan#features). The machine, transcription hours,
    # backup space and connections above stay for costing and are not shown
    # until each one ships; add it here when it does.
    def features
      { hosting: true, allowance_usd: Billing.usd(allowance_usd) }
    end

    # Money is a two-place decimal string in JSON ("9.99"), never a float.
    def as_json(*)
      {
        id: id, name: name, size: size, monthly_usd: Billing.usd(monthly_usd), allowance_usd: Billing.usd(allowance_usd),
        purchasable: purchasable?, features: features
      }
    end

  end
end
