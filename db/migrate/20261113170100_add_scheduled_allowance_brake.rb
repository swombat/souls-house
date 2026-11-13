class AddScheduledAllowanceBrake < ActiveRecord::Migration[8.1]

  def change
    add_column :agents, :allowance_brake_threshold_percent, :integer
    add_check_constraint :agents, "allowance_brake_threshold_percent BETWEEN 0 AND 100", name: "agents_allowance_brake_threshold"
    add_column :agents, :scheduled_wakes_essential, :boolean, default: false, null: false
    add_column :rhythms, :essential, :boolean, default: false, null: false
    add_column :commitments, :essential, :boolean, default: false, null: false
    add_column :rhythm_occurrences, :human_requested, :boolean, default: false, null: false

    create_table :allowance_brake_readings do |t|
      t.references :agent, null: false, foreign_key: true
      t.string :provider, null: false
      t.string :model, null: false
      t.jsonb :windows, null: false, default: []
      t.datetime :observed_at
      t.datetime :checked_at
      t.datetime :refresh_requested_at
      t.timestamps
      t.index [ :agent_id, :provider, :model ], unique: true
    end

    create_table :allowance_brake_notices do |t|
      t.references :agent, null: false, foreign_key: true
      t.string :provider, null: false
      t.string :window_key, null: false
      t.datetime :resets_at
      t.timestamps
      t.index [ :agent_id, :provider, :window_key ], unique: true
    end
  end

end
