# One bill per account (docs/proposals/2026-11-14-one-bill.md): a change to an
# account's bill is one record, whatever it changes. A resident's row no
# longer stands for one Stripe item, so several rows may share a subscription
# with no item id.
class CreateBillChanges < ActiveRecord::Migration[8.1]

  def change
    create_table :bill_changes do |t|
      t.references :account, null: false, foreign_key: true, index: false
      t.references :requested_by, foreign_key: { to_table: :users }
      t.string :state, null: false, default: "proposed"
      t.string :stripe_subscription_id, null: false
      t.string :idempotency_key, null: false
      t.jsonb :ops, null: false
      t.jsonb :base, null: false
      t.jsonb :lines, null: false
      t.jsonb :params, null: false
      t.jsonb :quote, null: false
      t.string :problem
      t.datetime :submitted_at
      t.datetime :resolved_at
      t.timestamps
      t.index :idempotency_key, unique: true
      t.index :account_id, unique: true, where: "resolved_at IS NULL", name: "one_unresolved_bill_change_per_account"
      t.check_constraint "state IN ('proposed', 'submitted', 'applied', 'abandoned')", name: "bill_changes_state"
    end

    # A paid creation in an account that already pays is a bill change.
    add_reference :resident_birth_orders, :bill_change, foreign_key: true

    remove_index :resident_subscriptions, name: "one_unitemised_row_per_subscription", column: :stripe_subscription_id,
      unique: true, where: "(stripe_subscription_item_id IS NULL)"
  end

end
