# The free trial (Billing::Trial): a small resident for 14 days without a
# card, once per account, ever. The account remembers when it claimed it; a
# trial birth order pins the Stripe Checkout it opens; the resident's
# subscription remembers when Stripe ends the trial. Site Admin switches the
# offer (on by default).
class AddFreeTrial < ActiveRecord::Migration[8.1]

  def change
    add_column :accounts, :trial_started_at, :datetime

    add_column :resident_birth_orders, :trial, :boolean, null: false, default: false
    add_column :resident_birth_orders, :stripe_checkout_session_id, :string
    # The Checkout payload, pinned: an uncertain create is replayed with the
    # same idempotency key, and Stripe refuses a key whose parameters moved.
    add_column :resident_birth_orders, :checkout_create_params, :jsonb
    add_index :resident_birth_orders, :stripe_checkout_session_id, unique: true
    # Once per account: one trial order that is waiting, born or failed. The
    # claim on accounts.trial_started_at refuses first; this is the backstop.
    add_index :resident_birth_orders, :account_id, unique: true,
      where: "trial AND state IN ('pending', 'born', 'failed')", name: "index_resident_birth_orders_one_trial_per_account"

    add_column :resident_subscriptions, :trial_end, :datetime

    add_column :settings, :free_trial_enabled, :boolean, null: false, default: true
  end

end
