# A paid plan's house-model allowance belongs to the resident, through its
# entitlement (docs/proposals/2026-10-07-stripe-billing.md, "Allowance and
# ledger"). A house call is charged to exactly one ledger: the legacy user
# grant or the resident's paid entitlement. Every new call also records the
# resident it was made for, so per-resident cost is attributable from now on.
#
# allowance_month / allowance_limit_usd remember the highest paid allowance
# in force during the current UTC month, so a mid-month downgrade or a lapse
# and repayment never refills the month's budget.
class AddPaidHouseAllowance < ActiveRecord::Migration[8.1]

  def change
    change_column_null :house_inference_calls, :house_inference_grant_id, true
    add_reference :house_inference_calls, :agent, foreign_key: true, index: true
    add_reference :house_inference_calls, :resident_entitlement, foreign_key: true, index: false
    add_index :house_inference_calls, [ :resident_entitlement_id, :month ], name: "index_house_calls_on_entitlement_month"
    add_check_constraint :house_inference_calls,
      "num_nonnulls(house_inference_grant_id, resident_entitlement_id) = 1",
      name: "house_calls_one_ledger"

    add_column :resident_entitlements, :allowance_month, :date
    add_column :resident_entitlements, :allowance_limit_usd, :decimal, precision: 14, scale: 8
  end

end
