class CreateVisitsAndVisitWakes < ActiveRecord::Migration[8.1]
  def change
    create_table :visits do |t|
      t.references :agent, null: false, foreign_key: true
      t.references :created_by, foreign_key: { to_table: :users }
      t.string :visited_origin, null: false
      t.string :visited_house_name
      t.string :visited_account_name
      t.string :local_name
      t.text :visit_token, null: false
      t.string :status, null: false, default: "active"
      t.integer :max_wakes_per_hour, null: false, default: 12
      t.datetime :ended_at
      t.datetime :last_polled_at
      t.datetime :last_wake_at
      t.string :last_error
      t.integer :consecutive_errors, null: false, default: 0

      t.timestamps
    end

    add_index :visits, [ :agent_id, :status ]
    add_index :visits, :status

    create_table :visit_wakes do |t|
      t.references :visit, null: false, foreign_key: true
      t.string :remote_wake_id, null: false
      t.string :remote_conversation_id, null: false
      t.string :remote_message_id
      t.string :reason
      t.references :agent_runtime_interaction, foreign_key: true
      t.datetime :dispatched_at
      t.datetime :completed_at

      t.timestamps
    end

    add_index :visit_wakes, [ :visit_id, :remote_wake_id ], unique: true
    add_index :visit_wakes, [ :visit_id, :created_at ]
  end
end
