class CreateRoomModelDefaults < ActiveRecord::Migration[8.1]

  # The model a resident starts on in new conversations in a room. Main is not
  # a row, so its defaults have no room_id; each (account, room, resident) has
  # at most one.
  def change
    create_table :room_model_defaults do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }
      t.references :room, foreign_key: { on_delete: :cascade }
      t.references :agent, null: false, foreign_key: { on_delete: :cascade }
      t.string :model_id, null: false
      t.timestamps
    end
    add_index :room_model_defaults, %i[account_id room_id agent_id], unique: true,
      where: "room_id IS NOT NULL", name: "index_room_model_defaults_unique_in_room"
    add_index :room_model_defaults, %i[account_id agent_id], unique: true,
      where: "room_id IS NULL", name: "index_room_model_defaults_unique_in_main"
  end

end
