# An at-cost resident pays for the machine it lives on: Boat ("at_cost", the
# name kept from when it was the only one) or Hetzner ("at_cost_hetzner")
# (Billing::Tier::RATES; Daniel, YzmwQJ 2026-11-16). No existing row changes.
class AddAtCostHetznerRate < ActiveRecord::Migration[8.1]

  TABLES = %i[resident_subscriptions resident_entitlements resident_birth_orders].freeze

  def up
    TABLES.each do |table|
      remove_check_constraint table, name: "#{table}_rate_known"
      add_check_constraint table, "rate IN ('standard', 'at_cost', 'at_cost_hetzner')", name: "#{table}_rate_known"
    end
  end

  def down
    TABLES.each do |table|
      remove_check_constraint table, name: "#{table}_rate_known"
      add_check_constraint table, "rate IN ('standard', 'at_cost')", name: "#{table}_rate_known"
    end
  end

end
