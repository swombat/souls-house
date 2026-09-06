class AddRuntimeActivity < ActiveRecord::Migration[8.1]

  def change
    add_column :agents, :share_working_narration, :boolean, default: false, null: false
    add_column :agent_runtime_interactions, :run_id, :string
    add_index :agent_runtime_interactions, :run_id, unique: true
    add_column :agent_runtime_interactions, :execution_state, :string
    add_column :agent_runtime_interactions, :execution_deadline_at, :datetime
    add_column :agent_runtime_interactions, :dispatch_claimed_at, :datetime
    add_column :agent_runtime_interactions, :activity_token_digest, :string
    add_column :agent_runtime_interactions, :activity_token_expires_at, :datetime
    add_column :agent_runtime_interactions, :narration_shared, :boolean, default: false, null: false

    create_table :agent_runtime_attempts do |t|
      t.references :agent_runtime_interaction, null: false, foreign_key: true, index: false
      t.string :attempt_id, null: false
      t.integer :number, null: false
      t.integer :last_seq, null: false, default: 0
      t.integer :revision, null: false, default: 0
      t.datetime :last_report_at
      t.datetime :last_broadcast_at
      t.jsonb :snapshot, null: false, default: {}
      t.integer :detail_bytes, null: false, default: 0
      t.integer :detail_count, null: false, default: 0
      t.integer :dropped_count, null: false, default: 0
      t.timestamps
    end
    add_index :agent_runtime_attempts, :attempt_id, unique: true
    add_index :agent_runtime_attempts, [ :agent_runtime_interaction_id, :number ], unique: true, name: "idx_runtime_attempt_number"

    create_table :agent_runtime_events do |t|
      t.references :agent_runtime_attempt, null: false, foreign_key: true
      t.integer :seq, null: false
      t.string :event_type, null: false
      t.string :payload_digest, null: false
      t.jsonb :data, null: false, default: {}
      t.timestamps
    end
    add_index :agent_runtime_events, [ :agent_runtime_attempt_id, :seq ], unique: true, name: "idx_runtime_event_sequence"
    add_reference :messages, :runtime_interaction, foreign_key: { to_table: :agent_runtime_interactions }, index: true
  end

end
