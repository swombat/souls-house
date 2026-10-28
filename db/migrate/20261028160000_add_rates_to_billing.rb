# A plan can be bought at a rate (Billing::Offer): standard, or at cost with
# no allowance (docs/proposals/2026-10-28-billing-codes-at-cost.md). The
# subscription records the offer it bought and the Stripe price that sold it;
# the entitlement reflects its subscription; a birth order pins the price it
# was opened with, so an uncertain create is replayed with the same
# parameters after a re-costing (#619).
class AddRatesToBilling < ActiveRecord::Migration[8.1]

  def change
    %i[resident_subscriptions resident_entitlements resident_birth_orders].each do |table|
      add_column table, :rate, :string, null: false, default: "standard"
      add_check_constraint table, "rate IN ('standard', 'at_cost')", name: "#{table}_rate_known"
    end
    add_column :resident_subscriptions, :stripe_price_id, :string
    add_column :resident_birth_orders, :stripe_price_id, :string
  end

end
