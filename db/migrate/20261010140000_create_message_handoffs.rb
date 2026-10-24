# One row per (message, recipient): a resident's message asking another
# resident in the room to act, the request that wakes them, and the receipt
# shown under the message. See MessageHandoff.
class CreateMessageHandoffs < ActiveRecord::Migration[8.1]

  def change
    create_table :message_handoffs do |t|
      t.references :message, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.references :chat, null: false, foreign_key: true
      t.references :requester_agent, foreign_key: { to_table: :agents, on_delete: :nullify }
      t.references :recipient_agent, null: false, foreign_key: { to_table: :agents, on_delete: :cascade }
      t.string :source, null: false
      t.string :status, null: false, default: "pending"
      t.string :reason
      t.references :runtime_interaction, foreign_key: { to_table: :agent_runtime_interactions, on_delete: :nullify }
      t.references :pending_wake, foreign_key: { on_delete: :nullify }
      t.datetime :delivered_at
      t.timestamps

      t.index [ :message_id, :recipient_agent_id ], unique: true
      t.index [ :chat_id, :recipient_agent_id, :status ], name: "index_message_handoffs_on_chat_recipient_status"
      t.check_constraint "source IN ('tag', 'field')", name: "message_handoffs_source"
      t.check_constraint "status IN ('pending', 'triggered', 'held', 'delivered', 'blocked')", name: "message_handoffs_status"
    end
  end

end
