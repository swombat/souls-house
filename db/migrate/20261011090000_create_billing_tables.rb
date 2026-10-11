# Paid hosting (docs/proposals/2026-10-07-stripe-billing.md). One Stripe
# customer per account, one subscription per hosted resident, one entitlement
# per hosted resident, and every Stripe event recorded before it is applied.
#
# Existing hosted residents get a complimentary hosting entitlement with no new
# inference allowance (Daniel, 2026-10-11: existing residents stay free).
class CreateBillingTables < ActiveRecord::Migration[8.1]

  LIVE_STATUSES = "'incomplete', 'trialing', 'active', 'past_due'".freeze

  def up
    create_table :billing_customers do |t|
      t.references :account, null: false, foreign_key: true, index: { unique: true }
      t.string :stripe_customer_id, null: false
      t.timestamps
    end
    add_index :billing_customers, :stripe_customer_id, unique: true

    create_table :resident_subscriptions do |t|
      t.references :agent, null: false, foreign_key: true
      t.references :account, null: false, foreign_key: true
      t.string :stripe_subscription_id, null: false
      t.string :tier, null: false
      t.string :stripe_status, null: false
      t.datetime :current_period_end
      t.boolean :cancel_at_period_end, null: false, default: false
      t.datetime :last_synced_at
      t.timestamps
    end
    add_index :resident_subscriptions, :stripe_subscription_id, unique: true
    # At most one live subscription per resident. Checkout refuses first; this is the backstop.
    add_index :resident_subscriptions, :agent_id, unique: true,
      where: "stripe_status IN (#{LIVE_STATUSES})", name: "index_resident_subscriptions_one_live_per_agent"

    create_table :resident_entitlements do |t|
      t.references :agent, null: false, foreign_key: true, index: { unique: true }
      t.references :account, null: false, foreign_key: true
      t.string :source, null: false
      t.string :tier
      t.references :current_subscription, foreign_key: { to_table: :resident_subscriptions }
      t.string :state, null: false
      # Set when the house grants free hosting. A paid plan that later ends falls back to it.
      t.datetime :complimentary_granted_at
      t.datetime :grace_started_at
      t.datetime :grace_deadline
      t.jsonb :notices_sent, null: false, default: {}
      t.datetime :held_at
      t.datetime :hold_released_at
      t.timestamps
    end
    add_index :resident_entitlements, :state
    add_index :resident_entitlements, :grace_deadline, where: "state = 'grace'"

    create_table :stripe_events do |t|
      t.string :stripe_event_id, null: false
      t.string :event_type, null: false
      t.jsonb :payload, null: false, default: {}
      t.string :status, null: false, default: "received"
      t.integer :attempts, null: false, default: 0
      t.text :last_error
      t.datetime :processed_at
      t.timestamps
    end
    add_index :stripe_events, :stripe_event_id, unique: true
    add_index :stripe_events, [ :status, :updated_at ]

    execute <<~SQL
      INSERT INTO resident_entitlements
        (agent_id, account_id, source, state, complimentary_granted_at, notices_sent, created_at, updated_at)
      SELECT id, account_id, 'complimentary', 'complimentary', NOW(), '{}'::jsonb, NOW(), NOW()
      FROM agents
      WHERE runtime IN ('external', 'offline', 'provisioning')
    SQL
  end

  def down
    drop_table :stripe_events
    drop_table :resident_entitlements
    drop_table :resident_subscriptions
    drop_table :billing_customers
  end

end
