class CreateWorkCompletions < ActiveRecord::Migration[8.0]

  def change
    create_table :work_completions do |t|
      t.references :chat, null: false, foreign_key: true
      t.references :message, null: false, foreign_key: true
      t.references :agent, foreign_key: true
      t.references :user, foreign_key: true
      t.string :request_key, null: false
      t.integer :source_revision, null: false
      t.integer :review_revision, null: false
      t.text :changes_summary, null: false
      t.text :result, null: false
      t.text :checks, null: false
      t.text :remaining, null: false
      t.references :accepted_by, foreign_key: { to_table: :users }
      t.datetime :accepted_at
      t.integer :accepted_revision
      t.jsonb :closure_blocked
      t.datetime :closed_at
      t.timestamps
    end
    add_index :work_completions, [ :chat_id, :request_key ], unique: true

    create_table :work_completion_permissions do |t|
      t.references :chat, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.integer :work_revision, null: false
      t.boolean :auto_close, null: false, default: false
      t.datetime :revoked_at
      t.datetime :consumed_at
      t.timestamps
    end
    add_index :work_completion_permissions, [ :chat_id, :work_revision ]
  end

end
