# The plan includes its resident (Daniel, jaMWBj jRyMoO 2026-11-13, ePoEyY
# JygPKB 2026-11-14). The plan's own resident is on the bill at the "included"
# rate (Billing::Tier::RATES). A first purchase carries the plan line as well
# as the resident's, so an order records which plan and at what price; an
# account that has not paid yet keeps the plan it chose for its first bill.
# No existing row changes: the one paying account (at cost) has no plan line.
class AddIncludedRateAndPlanLines < ActiveRecord::Migration[8.1]

  TABLES = %i[resident_subscriptions resident_entitlements resident_birth_orders].freeze

  def up
    TABLES.each do |table|
      remove_check_constraint table, name: "#{table}_rate_known"
      add_check_constraint table, "rate IN ('standard', 'at_cost', 'at_cost_hetzner', 'included')",
        name: "#{table}_rate_known"
    end
    # Companions is paid for now, so its subscription is a row like the others.
    remove_check_constraint :account_subscriptions, name: "account_subscriptions_plan_paid"
    add_check_constraint :account_subscriptions, "plan IN ('companions', 'partners', 'colleagues')",
      name: "account_subscriptions_plan_paid"
    add_column :resident_birth_orders, :plan, :string
    add_column :resident_birth_orders, :plan_stripe_price_id, :string
    add_column :accounts, :chosen_plan, :string
    add_check_constraint :accounts, "chosen_plan IN ('companions', 'partners', 'colleagues')",
      name: "accounts_chosen_plan_known"
  end

  def down
    remove_check_constraint :accounts, name: "accounts_chosen_plan_known"
    remove_column :accounts, :chosen_plan
    remove_column :resident_birth_orders, :plan_stripe_price_id
    remove_column :resident_birth_orders, :plan
    remove_check_constraint :account_subscriptions, name: "account_subscriptions_plan_paid"
    add_check_constraint :account_subscriptions, "plan IN ('partners', 'colleagues')", name: "account_subscriptions_plan_paid"
    TABLES.each do |table|
      remove_check_constraint table, name: "#{table}_rate_known"
      add_check_constraint table, "rate IN ('standard', 'at_cost', 'at_cost_hetzner')", name: "#{table}_rate_known"
    end
  end

end
