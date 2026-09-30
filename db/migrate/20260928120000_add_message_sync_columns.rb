class AddMessageSyncColumns < ActiveRecord::Migration[8.0]

  # Native-app sync (issue #94, PR B). Each chat keeps a monotonic
  # message_revision; every message write takes the next one, so a client's
  # `changes?since=` is "rows with revision > since". Discard hides, never
  # erases (#92). client_message_id + submission_digest make app posts
  # idempotent and are never changed after create.
  def up
    add_column :chats, :message_revision, :bigint, null: false, default: 0
    add_column :messages, :revision, :bigint, null: false, default: 0
    add_column :messages, :discarded_at, :datetime
    add_column :messages, :client_message_id, :string
    add_column :messages, :submission_digest, :string

    add_index :messages, [ :chat_id, :revision ]
    add_index :messages, :discarded_at
    add_index :messages, [ :chat_id, :user_id, :client_message_id ], unique: true,
              where: "client_message_id IS NOT NULL", name: "index_messages_on_client_message_identity"

    # Existing messages get revisions 1..n per chat in id order, so a first
    # sync from 0 returns all of them.
    execute <<~SQL
      UPDATE messages SET revision = numbered.n
      FROM (SELECT id, row_number() OVER (PARTITION BY chat_id ORDER BY id) AS n FROM messages) numbered
      WHERE messages.id = numbered.id
    SQL
    execute <<~SQL
      UPDATE chats SET message_revision = counts.n
      FROM (SELECT chat_id, max(revision) AS n FROM messages GROUP BY chat_id) counts
      WHERE chats.id = counts.chat_id
    SQL
  end

  def down
    remove_index :messages, name: "index_messages_on_client_message_identity"
    remove_index :messages, :discarded_at
    remove_index :messages, [ :chat_id, :revision ]
    remove_column :messages, :submission_digest
    remove_column :messages, :client_message_id
    remove_column :messages, :discarded_at
    remove_column :messages, :revision
    remove_column :chats, :message_revision
  end

end
