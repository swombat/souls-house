# Repository watches: an account connects a repository once (one hook), and
# residents or people arm watches on it ("when CI finishes for this sha, post
# the result here and wake me once"). See
# docs/proposals/2026-10-10-repository-watches.md.
class CreateRepositoryWatches < ActiveRecord::Migration[8.0]

  def change
    create_table :watched_repositories do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }
      t.references :service_connection, null: false, foreign_key: { on_delete: :cascade }
      t.references :created_by_user, null: true, foreign_key: { to_table: :users, on_delete: :nullify }
      t.string :provider, null: false, default: "github"
      t.string :owner, null: false
      t.string :name, null: false
      t.string :full_name, null: false
      t.string :external_repository_id
      t.boolean :private_repository, null: false, default: true
      t.bigint :hook_id
      t.text :hook_secret, null: false
      t.string :receiver_token, null: false
      t.string :hook_status, null: false, default: "installing"
      t.string :hook_error
      t.datetime :last_delivery_at
      t.string :last_delivery_result
      t.datetime :removed_at
      t.timestamps
    end
    add_index :watched_repositories, :receiver_token, unique: true
    add_index :watched_repositories, [ :account_id, :provider, :full_name ], unique: true,
              where: "removed_at IS NULL", name: "index_watched_repositories_on_live_full_name"

    create_table :repository_watches do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }
      t.references :watched_repository, null: false, foreign_key: { on_delete: :cascade }
      t.references :chat, null: false, foreign_key: { on_delete: :cascade }
      t.references :created_by_agent, null: true, foreign_key: { to_table: :agents, on_delete: :nullify }
      t.references :created_by_user, null: true, foreign_key: { to_table: :users, on_delete: :nullify }
      t.string :event_kind, null: false
      t.jsonb :filter, null: false, default: {}
      t.bigint :wake_agent_ids, array: true, null: false, default: []
      t.boolean :one_shot, null: false, default: true
      t.string :state, null: false, default: "armed"
      t.datetime :expires_at, null: false
      t.datetime :fulfilled_at
      t.jsonb :fulfilment
      t.string :reconcile_status, null: false, default: "pending"
      t.string :reconcile_error
      t.datetime :cancelled_at
      t.string :cancel_reason
      t.string :undeliverable_reason
      t.timestamps
    end
    add_index :repository_watches, [ :watched_repository_id, :state, :event_kind ]
    add_index :repository_watches, [ :state, :expires_at ]

    create_table :repository_deliveries do |t|
      t.references :watched_repository, null: false, foreign_key: { on_delete: :cascade }
      t.string :delivery_guid, null: false
      t.string :event, null: false
      t.string :action
      t.datetime :received_at, null: false
      t.boolean :signature_ok, null: false, default: false
      t.datetime :processed_at
      t.jsonb :payload, null: false, default: {}
      t.timestamps
    end
    add_index :repository_deliveries, :delivery_guid, unique: true

    create_table :repository_watch_deliveries do |t|
      t.references :repository_watch, null: false, foreign_key: { on_delete: :cascade }
      t.string :fulfilment_key, null: false
      t.references :message, null: true, foreign_key: { on_delete: :nullify }
      t.jsonb :woken, null: false, default: {}
      t.integer :attempts, null: false, default: 0
      t.string :last_error
      t.datetime :completed_at
      t.timestamps
    end
    add_index :repository_watch_deliveries, [ :repository_watch_id, :fulfilment_key ], unique: true,
              name: "index_repository_watch_deliveries_on_watch_and_key"
  end

end
