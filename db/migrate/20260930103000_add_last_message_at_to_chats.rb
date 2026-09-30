class AddLastMessageAtToChats < ActiveRecord::Migration[8.1]

  def up
    add_column :chats, :last_message_at, :datetime
    execute <<~SQL
      UPDATE chats
      SET last_message_at = latest.sent_at
      FROM (SELECT chat_id, MAX(created_at) AS sent_at FROM messages GROUP BY chat_id) latest
      WHERE chats.id = latest.chat_id
    SQL
  end

  def down
    remove_column :chats, :last_message_at
  end

end
