class CreateAccountPortability < ActiveRecord::Migration[8.1]

  def change
    create_table :account_exports do |t|
      t.references :account, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.string :status, null: false, default: "queued"
      t.boolean :include_conversations, null: false, default: false
      t.jsonb :progress, null: false, default: {}
      t.jsonb :summary, null: false, default: {}
      t.string :error, limit: 1000
      t.datetime :finished_at
      t.datetime :expires_at
      t.timestamps
      t.check_constraint "status IN ('queued','running','ready','failed','expired')", name: "account_exports_status"
    end

    create_table :account_imports do |t|
      t.references :account, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.string :status, null: false, default: "uploaded"
      t.string :archive_sha256, limit: 64
      t.jsonb :preview, null: false, default: {}
      t.jsonb :ledger, null: false, default: {}
      t.string :error, limit: 1000
      t.datetime :confirmed_at
      t.datetime :finished_at
      t.timestamps
      t.check_constraint "status IN ('uploaded','validating','previewed','invalid','importing','imported','failed')", name: "account_imports_status"
    end

    # An imported reflex arrives held: never judged or offered until a person
    # releases it (docs/features/account-portability.md).
    add_column :reflexes, :held_at, :datetime
  end

end
