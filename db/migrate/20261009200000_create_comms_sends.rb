# Sending through a comms (WhatsApp) connection (spec §5). A resident sends
# only with an enabled access row that also carries can_send, which only the
# connection's owner can set. Every send is recorded in comms_sends before
# the connector is called; grants and withdrawals are recorded in
# comms_send_grant_events for the owner's connection page.
class CreateCommsSends < ActiveRecord::Migration[8.1]

  def change
    add_column :agent_service_accesses, :can_send, :boolean, default: false, null: false

    create_table :comms_sends do |t|
      t.references :service_connection, null: false, foreign_key: true, index: false
      t.references :agent, null: false, foreign_key: true
      t.references :comms_chat, null: false, foreign_key: true
      t.text :text, null: false
      t.string :client_request_id, null: false
      t.string :status, null: false, default: "pending"
      t.string :provider_message_id
      t.string :error_code
      t.datetime :requested_at, null: false
      t.datetime :sent_at
      t.timestamps
      # The idempotency claim: one record per (connection, resident, id).
      t.index [ :service_connection_id, :agent_id, :client_request_id ], unique: true, name: "index_comms_sends_on_claim"
      # Rate limits count rows per connection by request time.
      t.index [ :service_connection_id, :requested_at ]
      t.index [ :service_connection_id, :provider_message_id ], unique: true, where: "provider_message_id IS NOT NULL",
              name: "index_comms_sends_on_provider_message_id"
    end

    # Attribution is a separate reference, not part of the immutable body: it
    # is set by whichever of the echo and the send acknowledgement arrives
    # second.
    add_column :comms_messages, :from_me, :boolean, default: false, null: false
    add_reference :comms_messages, :comms_send, foreign_key: true, index: { unique: true }, null: true

    create_table :comms_send_grant_events do |t|
      t.references :service_connection, null: false, foreign_key: true
      t.references :agent, null: false, foreign_key: true
      # Nil when the house withdrew the grant itself (disconnect, re-pair,
      # owner change).
      t.references :actor_user, foreign_key: { to_table: :users }, null: true
      t.string :action, null: false
      t.string :reason, null: false
      t.datetime :created_at, null: false
    end
  end

end
