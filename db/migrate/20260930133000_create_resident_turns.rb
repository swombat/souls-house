class CreateResidentTurns < ActiveRecord::Migration[8.1]

  def change
    add_column :settings, :resident_turn_limit, :integer, null: false, default: 50
    create_table :resident_turns do |t|
      t.references :agent_runtime_interaction, null: false, index: { unique: true }, foreign_key: true
      t.references :agent, null: false, foreign_key: true
      t.string :dispatch_id, null: false
      t.string :session_id, null: false
      t.string :ledger_id
      t.string :state, null: false, default: "queued"
      t.text :payload, null: false
      t.jsonb :completion_context, null: false, default: {}
      t.datetime :admitted_at
      t.datetime :checked_at
      t.datetime :prepared_at
      t.datetime :poll_claimed_until
      t.datetime :cancel_requested_at
      t.datetime :finished_at
      t.timestamps
    end
    add_index :resident_turns, :dispatch_id, unique: true
    add_index :resident_turns, [ :state, :created_at ]
    add_index :resident_turns, :session_id, unique: true,
      where: "state IN ('starting', 'running', 'unknown')", name: "one_admitted_resident_session"
  end

end
