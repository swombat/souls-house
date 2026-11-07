class CreateBillingCheckoutAttempts < ActiveRecord::Migration[8.1]

  def change
    create_table :billing_checkout_attempts do |t|
      t.references :agent, null: false, foreign_key: true
      t.references :account, null: false, foreign_key: true
      t.references :billing_code_redemption, foreign_key: true
      t.string :tier, null: false
      t.string :rate, null: false
      t.string :stripe_price_id, null: false
      t.string :idempotency_key, null: false
      t.jsonb :create_params, null: false
      t.string :stripe_session_id
      t.datetime :resolved_at
      t.timestamps
    end
    add_index :billing_checkout_attempts, :idempotency_key, unique: true
    add_index :billing_checkout_attempts, :stripe_session_id, unique: true
    add_index :billing_checkout_attempts, :agent_id, unique: true,
      where: "resolved_at IS NULL", name: "one_unresolved_checkout_per_resident"
  end

end
