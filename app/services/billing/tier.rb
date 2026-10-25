# The server-owned plan catalogue. A Stripe price that isn't here is refused.
#
# Each plan's numbers were costed against what the house pays at full use
# (Lume's table in WjNvXj/YwkgkY, 2026-10-14; Daniel agreed): the Hetzner
# machine, the house-model allowance, Scribe transcription at $0.22/h, Restic
# backups at S3 list price, swarm reads and Stripe's fee. Every plan keeps a
# positive margin even when someone uses all of it. Change a number here and
# re-cost it.
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

    attr_reader :id, :name, :monthly_usd, :allowance_usd, :memory_gb, :cpu_shares, :server_type,
      :transcription_hours, :backup_gb, :swarm_searches, :connections

    def initialize(id:, name:, monthly_usd:, allowance_usd:, memory_gb:, cpu_shares:, server_type:,
      transcription_hours:, backup_gb:, swarm_searches: 0, connections: [])
      @id = id
      @name = name
      @monthly_usd = monthly_usd
      @allowance_usd = allowance_usd
      @memory_gb = memory_gb
      @cpu_shares = cpu_shares
      @server_type = server_type
      @transcription_hours = transcription_hours
      @backup_gb = backup_gb
      @swarm_searches = swarm_searches
      @connections = connections
    end

    CATALOGUE = [
      new(id: "conversation", name: "Conversation", monthly_usd: 20, allowance_usd: 8, memory_gb: 4, cpu_shares: 1024,
        server_type: "cx23", transcription_hours: 5, backup_gb: 10),
      new(id: "life", name: "Life", monthly_usd: 50, allowance_usd: 25, memory_gb: 8, cpu_shares: 2048,
        server_type: "cx33", transcription_hours: 20, backup_gb: 50, swarm_searches: 20, connections: CONNECTIONS),
      new(id: "work", name: "Work", monthly_usd: 100, allowance_usd: 45, memory_gb: 16, cpu_shares: 4096,
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
      return nil if price_id.blank?

      CATALOGUE.find { |tier| tier.price_id == price_id }
    end

    def self.with_swarm_search = CATALOGUE.select(&:swarm_search?)

    # Stripe price IDs differ between test and live mode, so they are configuration.
    def price_id
      Rails.application.credentials.dig(:stripe, :prices, id.to_sym).presence ||
        ENV["STRIPE_PRICE_#{id.upcase}"].presence
    end

    def purchasable? = price_id.present?

    def machine = MACHINES.fetch(server_type)

    def swarm_search? = swarm_searches.positive?

    # What the plan includes, for the public page, the Billing tab, the
    # creation wizard and the about-sheet. Only what a plan delivers today
    # (Daniel, 2026-10-25, going live): hosting for one resident, the monthly
    # house-model allowance (ResidentEntitlement) and swarm searches
    # (Account#swarm_searches). The machine, transcription hours, backup space
    # and connections above stay for costing and are not shown until each one
    # ships; add it here when it does.
    def features
      { hosting: true, allowance_usd: allowance_usd, swarm_searches: swarm_searches }
    end

    def as_json(*)
      {
        id: id, name: name, monthly_usd: monthly_usd, allowance_usd: allowance_usd,
        purchasable: purchasable?, features: features
      }
    end

  end
end
