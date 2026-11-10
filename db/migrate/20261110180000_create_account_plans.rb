# Account plans (Billing::AccountPlan): what an account can do, paid for
# separately from its residents. A site admin's grant lives on the account;
# a paid plan is an AccountSubscription, at most one live per account. The
# house-model allowance moves from each resident to one per account, carried
# by one live standard-rate resident subscription.
class CreateAccountPlans < ActiveRecord::Migration[8.1]

  LIVE_STATUSES = "'incomplete', 'trialing', 'active', 'past_due'".freeze

  def change
    add_column :accounts, :granted_plan, :string
    add_check_constraint :accounts, "granted_plan IN ('companions', 'partners', 'colleagues')",
      name: "accounts_granted_plan_known"

    create_table :account_subscriptions do |t|
      t.references :account, null: false, foreign_key: true
      t.string :stripe_subscription_id, null: false
      t.string :stripe_status, null: false
      t.string :plan, null: false
      t.string :stripe_price_id
      t.datetime :current_period_end
      t.boolean :cancel_at_period_end, null: false, default: false
      t.integer :plan_changes_count, null: false, default: 0
      # When Stripe first said past_due; the plan holds for Billing::GRACE_PERIOD from here.
      t.datetime :past_due_since
      t.datetime :last_synced_at
      t.timestamps
    end
    add_index :account_subscriptions, :stripe_subscription_id, unique: true
    # At most one live plan per account. Checkout refuses first; this is the backstop.
    add_index :account_subscriptions, :account_id, unique: true,
      where: "stripe_status IN (#{LIVE_STATUSES})", name: "index_account_subscriptions_one_live_per_account"
    add_check_constraint :account_subscriptions, "plan IN ('partners', 'colleagues')",
      name: "account_subscriptions_plan_paid"

    # Billing::AccountPlanCheckout's attempts, committed before Stripe is
    # called, as BillingCheckoutAttempt is for a resident's.
    create_table :account_plan_checkout_attempts do |t|
      t.references :account, null: false, foreign_key: true
      t.string :plan, null: false
      t.string :stripe_price_id, null: false
      t.string :idempotency_key, null: false
      t.jsonb :create_params, null: false
      t.string :stripe_session_id
      t.datetime :resolved_at
      t.timestamps
    end
    add_index :account_plan_checkout_attempts, :idempotency_key, unique: true
    add_index :account_plan_checkout_attempts, :stripe_session_id, unique: true
    add_index :account_plan_checkout_attempts, :account_id, unique: true, where: "resolved_at IS NULL",
      name: "one_unresolved_account_plan_checkout_per_account"

    # The Stripe description a paid birth opens its subscription with, pinned
    # like its price: an uncertain create is replayed under the same
    # idempotency key, and renaming the sizes must not move its parameters.
    add_column :resident_birth_orders, :stripe_description, :string

    add_column :resident_subscriptions, :includes_allowance, :boolean, null: false, default: false
    # One carrier per account: two webhooks can't both grant the allowance.
    add_index :resident_subscriptions, :account_id, unique: true, where: "includes_allowance",
      name: "index_resident_subscriptions_one_allowance_per_account"
  end

end
