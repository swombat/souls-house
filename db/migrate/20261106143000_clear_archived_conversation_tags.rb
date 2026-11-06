class ClearArchivedConversationTags < ActiveRecord::Migration[8.0]

  def up
    execute "UPDATE chats SET visual_tag_id = NULL WHERE archived_at IS NOT NULL AND visual_tag_id IS NOT NULL"
    execute <<~SQL
      UPDATE reply_expectations SET state = 2
      FROM messages, chats
      WHERE reply_expectations.message_id = messages.id
        AND messages.chat_id = chats.id
        AND chats.archived_at IS NOT NULL
        AND reply_expectations.state = 0
    SQL
  end

  def down
    # Cleared tags and dismissed flags are intentionally not restored.
  end

end
