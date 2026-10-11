class CreateRooms < ActiveRecord::Migration[8.1]

  def change
    create_table :rooms do |t|
      t.references :account, null: false, foreign_key: true
      t.string :name, null: false, limit: 40
      t.integer :position, null: false, default: 0
      t.timestamps
    end
    add_index :rooms, [ :id, :account_id ], unique: true
    add_index :rooms, "account_id, lower(name)", unique: true, name: "index_rooms_on_account_and_lower_name"

    add_reference :chats, :room
    # A composite FK keeps a conversation's room inside its own account.
    # Room#destroy moves its conversations to Main first, so account_id stays.
    add_foreign_key :chats, :rooms, column: [ :room_id, :account_id ], primary_key: [ :id, :account_id ]

    add_reference :accounts, :resident_room, foreign_key: { to_table: :rooms, on_delete: :nullify }
  end

end
