class CreateConversationDrafts < ActiveRecord::Migration[8.1]

  def change
    create_table :conversation_drafts do |t|
      t.references :chat, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.text :content, null: false, default: ""
      t.bigint :revision, null: false, default: 0
      t.timestamps
    end
    add_index :conversation_drafts, [ :chat_id, :user_id ], unique: true
  end

end
