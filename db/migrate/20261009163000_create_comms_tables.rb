# WhatsApp (and later Telegram) chats and messages for a ServiceConnection
# whose session lives in the comms connector. Names, senders, bodies and
# captions are encrypted like credential_payload. Upserts key on the provider
# IDs, so a replayed connector event is a no-op.
class CreateCommsTables < ActiveRecord::Migration[8.1]

  def change
    create_table :comms_chats do |t|
      t.references :service_connection, null: false, foreign_key: true
      t.string :provider_chat_id, null: false
      t.text :name
      t.string :kind
      t.datetime :last_activity_at
      t.timestamps
      t.index [ :service_connection_id, :provider_chat_id ], unique: true
      t.index [ :service_connection_id, :last_activity_at ]
    end

    create_table :comms_messages do |t|
      t.references :service_connection, null: false, foreign_key: true, index: false
      t.references :comms_chat, null: false, foreign_key: true, index: false
      t.string :provider_message_id, null: false
      t.text :sender_id
      t.text :sender_name
      t.datetime :sent_at, null: false
      t.text :body
      t.string :media_kind
      t.text :caption
      t.timestamps
      t.index [ :service_connection_id, :provider_message_id ], unique: true
      t.index [ :comms_chat_id, :sent_at, :id ]
    end

    # Connector request nonces seen inside the signature window. The unique
    # index is the replay check, as for runner_request_nonces.
    create_table :comms_request_nonces do |t|
      t.references :service_connection, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.string :nonce, null: false
      t.datetime :created_at, null: false
      t.index [ :service_connection_id, :nonce ], unique: true
      t.index :created_at
    end

    # The current pairing QR, encrypted, shown only to the owner until it
    # expires or pairing finishes.
    add_column :service_connections, :pairing_qr, :text
    add_column :service_connections, :pairing_qr_expires_at, :datetime
    add_column :service_connections, :pairing_qr_issued_at, :datetime
  end

end
