class AddChatClientIdentity < ActiveRecord::Migration[8.0]

  # Native-app sync (issue #94 B, step 4b-iii). A conversation created from
  # the app carries a client-generated identity and a digest of what was
  # asked for, so a lost-response retry finds the same conversation instead
  # of creating a second one. Written at create and never changed.
  def change
    add_column :chats, :client_conversation_id, :string
    add_column :chats, :creation_digest, :string
    add_index :chats, [ :account_id, :client_conversation_id ], unique: true,
              where: "client_conversation_id IS NOT NULL", name: "index_chats_on_client_conversation_identity"
  end

end
