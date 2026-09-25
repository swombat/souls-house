class CreateAgentBookmarks < ActiveRecord::Migration[8.1]

  def change
    create_table :agent_bookmarks do |t|
      t.references :chat_agent, null: false, index: { unique: true }, foreign_key: { on_delete: :cascade }
      t.text :note, null: false
      t.timestamps
    end
  end

end
