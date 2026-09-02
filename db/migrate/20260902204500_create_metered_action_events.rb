class CreateMeteredActionEvents < ActiveRecord::Migration[8.1]

  def change
    create_table :metered_action_events do |t|
      t.references :account, null: false, foreign_key: true
      t.references :agent, null: false, foreign_key: true
      t.string :action, null: false
      t.string :request_id, null: false
      t.string :outcome, null: false, default: "admitted"
      t.string :provider
      t.string :provider_request_id
      t.bigint :cost_in_usd_ticks
      t.jsonb :usage, null: false, default: {}
      t.datetime :outcome_recorded_at
      t.timestamps
    end

    add_index :metered_action_events, :request_id, unique: true
    add_index :metered_action_events, [ :action, :agent_id, :created_at ]
    add_index :metered_action_events, [ :action, :account_id, :created_at ]
  end

end
