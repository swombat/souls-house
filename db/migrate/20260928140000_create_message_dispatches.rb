class CreateMessageDispatches < ActiveRecord::Migration[8.0]

  # One automatic mention-wake per human message (#94 B, step 4b-ii). Written
  # in the same transaction as the message, so an accepted send's wake is
  # durable; the runtime interactions it reserves (the first and every chain
  # continuation) point back at it, so recovery and the claim-time checks can
  # find their source. Dispatch changes never bump message revisions.
  def change
    create_table :message_dispatches do |t|
      t.references :message, null: false, foreign_key: { on_delete: :cascade }, index: { unique: true }
      t.references :chat, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.jsonb :target_agent_ids, null: false, default: []
      t.string :status, null: false, default: "pending"
      t.string :reason
      t.references :runtime_interaction, foreign_key: { to_table: :agent_runtime_interactions, on_delete: :nullify }
      t.datetime :accepted_at, null: false
      t.datetime :expires_at, null: false
      t.datetime :settled_at
      t.timestamps
    end
    add_index :message_dispatches, [ :status, :accepted_at ]

    add_reference :agent_runtime_interactions, :message_dispatch, foreign_key: { on_delete: :nullify }
  end

end
