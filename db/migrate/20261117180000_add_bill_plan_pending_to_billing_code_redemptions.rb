# A plan code withdrawn under Build C's rule (PlanAfterGrant): the account's
# own plan is to go on its bill. Recorded at the withdrawal, so a withdrawal
# made under the old promise ("subscriptions already bought are unchanged")
# never becomes permission to add a plan (Mira, #1023). Cleared once the plan
# is on the bill or no longer applies.
class AddBillPlanPendingToBillingCodeRedemptions < ActiveRecord::Migration[8.1]

  def change
    add_column :billing_code_redemptions, :bill_plan_pending_since, :datetime
    add_index :billing_code_redemptions, :bill_plan_pending_since, where: "bill_plan_pending_since IS NOT NULL"
  end

end
