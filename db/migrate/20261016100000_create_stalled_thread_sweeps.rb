class CreateStalledThreadSweeps < ActiveRecord::Migration[8.1]

  def change
    # 0 = off; otherwise how long a room must be quiet before it is judged.
    add_column :settings, :stalled_sweep_minutes, :integer, null: false, default: 0

    create_table :stalled_thread_sweeps do |t|
      t.references :account, null: false, foreign_key: true
      t.references :chat, null: false, foreign_key: true
      # The room state judged: its last message when the sweep ran. One
      # verdict per state, so a quiet room costs one call, not one per tick.
      t.references :message, null: false, foreign_key: true
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
