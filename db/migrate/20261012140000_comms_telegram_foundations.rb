# Telegram personal connections (proposal 2026-10-11, S1).
#
# - Message identity is per chat, not per connection: Telegram numbers
#   channel and supergroup messages per peer, so the same id appears in two
#   chats of one account. WhatsApp ids are unique per connection already, so
#   the narrower key changes nothing for them.
# - Edits and deletions: edited_at and edit_version (the provider's edit
#   time, so an older edit never overwrites a newer one), and a deleted_at
#   tombstone that keeps the row and blanks the content. An edit or deletion
#   that arrives before its original leaves a placeholder row: the content
#   (or its absence) is kept, and the original's delivery only fills in who
#   sent it and when.
# - sync_state on each chat: whether it is synced and why not, how far back
#   the history goes and how fresh it is.
# - On the connection: the login generation (a replayed or delayed login
#   command or event for an older attempt is refused), connector_state (login
#   step and pool availability), and the highest event sequence Rails has
#   committed, which is the connector's acknowledgement.
class CommsTelegramFoundations < ActiveRecord::Migration[8.1]

  def change
    change_table :comms_messages, bulk: true do |t|
      t.datetime :edited_at
      t.bigint :edit_version
      t.datetime :deleted_at
      t.boolean :placeholder, default: false, null: false
    end
    remove_index :comms_messages, [ :service_connection_id, :provider_message_id ],
                 unique: true, name: "idx_on_service_connection_id_provider_message_id_12b2c5454b"
    add_index :comms_messages, [ :comms_chat_id, :provider_message_id ], unique: true
    add_index :comms_messages, :service_connection_id

    add_column :comms_chats, :sync_state, :jsonb, default: {}, null: false

    change_table :service_connections, bulk: true do |t|
      t.integer :login_generation, default: 0, null: false
      t.jsonb :connector_state, default: {}, null: false
      t.bigint :comms_event_seq, default: 0, null: false
    end
  end

end
