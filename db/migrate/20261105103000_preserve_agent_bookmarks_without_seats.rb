class PreserveAgentBookmarksWithoutSeats < ActiveRecord::Migration[8.1]

  def up
    add_reference :agent_bookmarks, :agent, foreign_key: { on_delete: :cascade }
    add_reference :agent_bookmarks, :chat, foreign_key: { on_delete: :cascade }
    execute <<~SQL
      UPDATE agent_bookmarks
      SET agent_id = chat_agents.agent_id, chat_id = chat_agents.chat_id
      FROM chat_agents WHERE chat_agents.id = agent_bookmarks.chat_agent_id
    SQL
    change_column_null :agent_bookmarks, :agent_id, false
    change_column_null :agent_bookmarks, :chat_id, false
    add_index :agent_bookmarks, [ :agent_id, :chat_id ], unique: true
    change_column_null :agent_bookmarks, :chat_agent_id, true
    remove_foreign_key :agent_bookmarks, :chat_agents
    add_foreign_key :agent_bookmarks, :chat_agents, on_delete: :nullify
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Detached resident notes must not be erased to restore mandatory seats"
  end

end
