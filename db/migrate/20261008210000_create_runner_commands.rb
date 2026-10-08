class CreateRunnerCommands < ActiveRecord::Migration[8.1]

  def change
    create_table :runner_commands do |t|
      t.string :public_id, null: false
      t.references :runner_enrollment, null: false, foreign_key: true
      t.references :agent_placement, null: false, foreign_key: true
      t.integer :generation, null: false
      t.string :kind, null: false
      # Encrypted: start_resident carries the resident's tokens. Cleared once
      # the runner has answered.
      t.text :payload_json
      t.string :state, null: false, default: "queued"
      t.integer :delivery_count, null: false, default: 0
      t.datetime :delivered_at
      t.jsonb :result
      t.datetime :finished_at
      t.references :resident_turn, foreign_key: true
      t.timestamps
    end
    add_index :runner_commands, :public_id, unique: true
    add_index :runner_commands, [ :runner_enrollment_id, :state, :id ]
  end

end
