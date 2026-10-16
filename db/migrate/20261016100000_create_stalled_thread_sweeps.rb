class CreateStalledThreadSweeps < ActiveRecord::Migration[8.1]

  def change
    # Site kill switch: 0 = off; otherwise how long a room must be quiet
    # before it is judged.
    add_column :settings, :stalled_sweep_minutes, :integer, null: false, default: 0
    # Accounts opt in one by one; no room in an account that hasn't is read.
    add_column :accounts, :stalled_sweep_enabled, :boolean, null: false, default: false

    create_table :stalled_thread_sweeps do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }
      t.references :chat, null: false, foreign_key: { on_delete: :cascade }
      # The room state judged: its last message when the sweep ran. One
      # verdict per state, so a quiet room costs one call, not one per tick.
      # A verdict goes with the room, message or account it is about.
      t.references :message, null: false, foreign_key: { on_delete: :cascade }
      t.string :outcome, null: false
      t.jsonb :scores, null: false, default: []
      t.float :person_holds
      t.jsonb :would_wake, null: false, default: []
      t.integer :quiet_minutes
      t.string :prompt_version
      t.string :error_class
      t.timestamps
    end
    add_index :stalled_thread_sweeps, [ :chat_id, :message_id ], unique: true
    add_index :stalled_thread_sweeps, :created_at
  end

end
