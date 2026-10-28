# Each plan change the house asks Stripe for gets its own idempotency key
# (Billing::PlanChange): the count is bumped in the same transaction as the
# Stripe call, so a change whose answer was lost is retried under the same
# key, and A->B->A->B is four performed changes, not one replayed.
class AddPlanChangesCountToResidentSubscriptions < ActiveRecord::Migration[8.1]

  def change
    add_column :resident_subscriptions, :plan_changes_count, :integer, null: false, default: 0
  end

end
