# Billing codes and their redemptions (docs/proposals/2026-10-28-billing-codes-at-cost.md).
# A code is the invitation; redeeming it on an account is the grant: while an
# account holds a live redemption whose effect is at_cost, it may buy plans
# at that rate. A birth order names the redemption that authorised it, so a
# grant withdrawn between the order and its webhook is not read as abuse.
class CreateBillingCodes < ActiveRecord::Migration[8.1]

  def change
    create_table :billing_codes do |t|
      t.string :code, null: false
      t.string :effect, null: false
      t.integer :max_redemptions
      t.integer :redemptions_count, null: false, default: 0
      t.datetime :expires_at
      t.datetime :revoked_at
      t.references :created_by, null: false, foreign_key: { to_table: :users }
      t.text :note
      t.timestamps
    end
    add_index :billing_codes, "lower(code)", unique: true, name: "index_billing_codes_on_lower_code"
    add_check_constraint :billing_codes, "effect IN ('at_cost')", name: "billing_codes_effect_known"

    create_table :billing_code_redemptions do |t|
      t.references :account, null: false, foreign_key: true
      t.references :billing_code, null: false, foreign_key: true
      t.string :effect, null: false
      t.references :redeemed_by, null: false, foreign_key: { to_table: :users }
      t.datetime :redeemed_at, null: false
      t.datetime :withdrawn_at
      t.references :withdrawn_by, foreign_key: { to_table: :users }
      t.timestamps
    end
    add_index :billing_code_redemptions, [ :account_id, :billing_code_id ], unique: true,
      name: "index_billing_code_redemptions_once_per_account"
    add_index :billing_code_redemptions, :account_id, where: "withdrawn_at IS NULL",
      name: "index_billing_code_redemptions_live_by_account"

    add_reference :resident_birth_orders, :billing_code_redemption, foreign_key: true

    # One Checkout attempt per idempotency key: the offer and the grant it
    # was authorised by, committed before Stripe is called, so a replay of
    # the key sends the same payload whatever the account's grants are by
    # then. An attempt whose answer was lost (no session id) is recovered by
    # its key, never overwritten by an attempt at another offer; one whose
    # key can no longer be replayed is marked abandoned.
    create_table :checkout_attempts do |t|
      t.references :agent, null: false, foreign_key: true
      t.string :idempotency_key, null: false
      t.string :offer_id, null: false
      t.references :billing_code_redemption, foreign_key: true
      t.string :stripe_session_id
      t.datetime :abandoned_at
      t.timestamps
    end
    add_index :checkout_attempts, :idempotency_key, unique: true
  end

end
