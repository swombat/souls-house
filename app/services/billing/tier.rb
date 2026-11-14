# The server-owned catalogue of resident sizes. A Stripe price that isn't
# here is refused. Every resident is paid for by its size; what the account
# can do (members, swarm searches, sub-agents) is its plan, a separate charge
# (Billing::AccountPlan). The ids are the original plan names and stay: they
# are in the database, Stripe metadata and the credentials keys. People see
# the size: Small, Medium, Large (2026-11-10).
#
# A size is a machine and nothing else (Daniel, jaMWBj 2026-11-13: "The
# resident is just a machine size. The allowances are per account."). The
# transcription hours and backup space are the account plan's
# (Billing::AccountPlan), like swarm searches and the house-model allowance.
# Each size is priced as if its Boat machine ran all month (Daniel, jaMWBj
# 2026-11-13); tier_test holds the working. Small is the exception: it sleeps
# on Boat after 15 idle minutes, and a Small awake most of the day moves to a
# CX23, so its worst month is the CX23's, not Boat small's (ePoEyY).
# Change a number here and re-cost it. The house-model allowance is $10 a
# month per account, shared by its standard-rate residents
# (ResidentEntitlement#allowance_limit). allowance_usd here is that account
# allowance, which a standard-rate resident of any size draws on.
#
# memory_gb and cpu_shares are the container limits while residents still live
# on the shared house server. boat_size is the machine a size is sold as.
# server_type is the Hetzner type a VM birth orders today
# (CloudProcurement#vm_birth_server_type); it goes when placement moves to
# Boat (ePokyY), and costs nothing in the prices below.
module Billing
  class Tier

    # Boat's sizes (boat.dev/llms.txt and docs.boat.dev, read 2026-11-13/14):
    # billed per second while running, nothing while stopped. disk_gb is the
    # user disk; the OS sits outside it.
    BOAT_MACHINES = {
      "small" => { vcpus: 2, ram_gb: 4, disk_gb: 51, hourly_usd: BigDecimal("0.018") },
      "default" => { vcpus: 4, ram_gb: 8, disk_gb: 51, hourly_usd: BigDecimal("0.036") },
      "large" => { vcpus: 8, ram_gb: 16, disk_gb: 111, hourly_usd: BigDecimal("0.072") }
    }.freeze

    # The Hetzner types a VM birth can order today, to describe a resident
    # already on one (Agents::HostingLocation, admin). Not what a size is
    # sold as and not in its price.
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
    # machine at its worst month and Stripe's UK fee on an EU card, rounded up
    # to the dollar; the test holds the working. Small's worst month is a
    # CX23 (net Hetzner list price, reverse charge, at ECB 1.115 USD/EUR, with
    # its IPv4); Medium and Large are Boat default and large running all
    # month (re-costed 2026-11-14, ePoEyY). No house-model allowance. Re-cost
    # by hand when a provider or the exchange rate moves: that makes a new
    # Stripe price, and the old id stays in the list (#619).
    AT_COST_MONTHLY_USD = { "conversation" => BigDecimal("8"), "life" => BigDecimal("28"), "work" => BigDecimal("55") }.freeze

    # The house-model allowance, per account per UTC month, shared by every
    # resident whose plan funds calls at the standard rate.
    ACCOUNT_ALLOWANCE_USD = BigDecimal("10")

    SIZES = %w[small medium large].freeze

    attr_reader :id, :name, :size, :monthly_usd, :allowance_usd, :memory_gb, :cpu_shares, :server_type,
      :boat_size, :connections

    def initialize(id:, name:, size:, monthly_usd:, memory_gb:, cpu_shares:, server_type:, boat_size:,
      connections: [])
      @id = id
      @name = name
      @size = size
      @monthly_usd = BigDecimal(monthly_usd)
      @allowance_usd = ACCOUNT_ALLOWANCE_USD
      @memory_gb = memory_gb
      @cpu_shares = cpu_shares
      @server_type = server_type
      @boat_size = boat_size
      @connections = connections
    end

    CATALOGUE = [
      new(id: "conversation", name: "Small", size: "small", monthly_usd: "9.99", memory_gb: 4, cpu_shares: 1024,
        server_type: "cx23", boat_size: "small"),
      new(id: "life", name: "Medium", size: "medium", monthly_usd: "39.99", memory_gb: 8, cpu_shares: 2048,
        server_type: "cx33", boat_size: "default", connections: CONNECTIONS),
      new(id: "work", name: "Large", size: "large", monthly_usd: "69.99", memory_gb: 16, cpu_shares: 4096,
        server_type: "cx43", boat_size: "large", connections: CONNECTIONS)
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

    # The machine the size is sold as: Boat's, without its price.
    def machine = BOAT_MACHINES.fetch(boat_size).except(:hourly_usd)

    # Boat's price for the machine running all month (730 hours).
    def boat_full_month_usd = BOAT_MACHINES.fetch(boat_size)[:hourly_usd] * 730

    # What the size includes, for the public page, the Billing tab, the
    # creation wizard and the about-sheet. Only what a size delivers today:
    # hosting for one resident, and the account's house-model allowance it
    # draws on, shared with the account's other standard-rate residents
    # (allowance_usd). Swarm searches and sub-agents are the account plan's
    # (Billing::AccountPlan#features). Connections above are not shown until
    # they ship; add them here when they do.
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
