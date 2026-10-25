# A resident someone has asked for in an account that pays per resident,
# waiting for its first payment. The resident itself is created only once
# Stripe says the plan is paid (docs/proposals/2026-10-07-stripe-billing.md,
# "Paying at creation").
class CreateResidentBirthOrders < ActiveRecord::Migration[8.1]

  def change
    create_table :resident_birth_orders do |t|
      t.references :account, null: false, foreign_key: true
      t.references :creator, null: false, foreign_key: { to_table: :users }
      t.references :agent, foreign_key: true, index: { unique: true }
      t.string :tier, null: false
      t.string :state, null: false, default: "pending"
      t.string :stripe_subscription_id, index: { unique: true }
      # The draft: name, soul seed, model, appearance. Cleared once the
      # resident is born or the order is abandoned.
      t.jsonb :birth_attributes, null: false, default: {}
      t.boolean :open_beginning, null: false, default: false
      t.text :last_error
      t.datetime :expires_at, null: false
      t.datetime :born_at
      t.timestamps
    end
    add_index :resident_birth_orders, [ :state, :expires_at ]
    add_check_constraint :resident_birth_orders, "state IN ('pending', 'born', 'abandoned', 'failed')",
      name: "resident_birth_orders_state_known"
  end

end
