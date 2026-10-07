class CreateRhythms < ActiveRecord::Migration[8.1]

  def change
    create_table :rhythms do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }
      t.references :creator, null: false, foreign_key: { to_table: :users }
      t.string :title, null: false
      t.boolean :append_date, null: false, default: true
      t.text :opening, null: false
      t.string :cadence, null: false
      t.string :time_of_day, null: false
      t.integer :weekday
      t.integer :month_day
      t.integer :month
      t.string :timezone, null: false
      t.datetime :next_run_at, null: false
      t.timestamps
    end
    add_index :rhythms, :next_run_at

    create_table :rhythm_agents do |t|
      t.references :rhythm, null: false, foreign_key: { on_delete: :cascade }
      t.references :agent, null: false, foreign_key: { on_delete: :cascade }
      t.timestamps
    end
    add_index :rhythm_agents, [ :rhythm_id, :agent_id ], unique: true

    create_table :rhythm_holds do |t|
      t.references :rhythm, null: false, foreign_key: { on_delete: :cascade }
      t.string :kind, null: false
      t.references :user, foreign_key: { on_delete: :nullify }
      t.references :agent, foreign_key: { on_delete: :nullify }
      t.text :reason, null: false
      t.datetime :released_at
      t.timestamps
    end
    add_index :rhythm_holds, [ :rhythm_id, :kind ], unique: true,
      where: "released_at IS NULL AND kind = 'system'", name: "index_rhythm_holds_one_open_system"
    add_index :rhythm_holds, [ :rhythm_id, :user_id ], unique: true,
      where: "released_at IS NULL AND kind = 'human'", name: "index_rhythm_holds_one_open_human"
    add_index :rhythm_holds, [ :rhythm_id, :agent_id ], unique: true,
      where: "released_at IS NULL AND kind = 'agent'", name: "index_rhythm_holds_one_open_agent"

    create_table :rhythm_occurrences do |t|
      t.references :rhythm, foreign_key: { on_delete: :nullify }
      t.references :chat, null: false, foreign_key: { on_delete: :cascade }
      t.references :message, null: false, foreign_key: { on_delete: :cascade }, index: { unique: true }
      t.references :creator, foreign_key: { to_table: :users, on_delete: :nullify }
      t.string :creator_label, null: false
      t.string :title, null: false
      t.string :rhythm_title, null: false
      t.text :opening, null: false
      t.datetime :scheduled_for, null: false
      t.boolean :manual, null: false, default: false
      t.string :request_key
      t.timestamps
    end
    add_index :rhythm_occurrences, [ :rhythm_id, :scheduled_for ], unique: true,
      where: "manual = false", name: "index_rhythm_occurrences_scheduled_identity"
    add_index :rhythm_occurrences, [ :rhythm_id, :request_key ], unique: true,
      where: "manual = true", name: "index_rhythm_occurrences_manual_identity"
    add_check_constraint :rhythm_occurrences,
      "(manual = true AND request_key IS NOT NULL) OR (manual = false AND request_key IS NULL)",
      name: "rhythm_occurrences_request_identity"
  end

end
