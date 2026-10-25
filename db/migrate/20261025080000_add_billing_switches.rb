# The site's billing switch and each account's copy of it (Daniel, oewbQY
# 2026-10-25). Accounts created while the switch is on pay for every new
# resident; accounts that already exist keep billing_required off, so their
# residents stay on the house.
class AddBillingSwitches < ActiveRecord::Migration[8.1]

  def change
    add_column :settings, :billing_enabled, :boolean, default: false, null: false
    add_column :settings, :billing_enabled_at, :datetime
    add_column :accounts, :billing_required, :boolean, default: false, null: false
  end

end
