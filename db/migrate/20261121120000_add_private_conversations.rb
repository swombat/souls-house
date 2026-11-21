# Private conversations (eKmnrJ): a chat marked private at creation is
# visible only to the people in it. A human is in it once they created it or
# posted in it, recorded here durably, never derived from surviving
# messages. A resident is in it while it holds a seat (chat_agents).
class AddPrivateConversations < ActiveRecord::Migration[8.0]

  def change
    add_column :chats, :private, :boolean, default: false, null: false

    create_table :chat_participants do |t|
      t.references :chat, null: false, foreign_key: { on_delete: :cascade }
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.string :source, null: false
      t.datetime :created_at, null: false
    end
    add_index :chat_participants, %i[chat_id user_id], unique: true
  end

end
