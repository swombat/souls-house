class AddInvocationsToMessageDispatches < ActiveRecord::Migration[8.0]

  # A native explicit invoke is a dispatch with no source message (#94 B,
  # keyed-invoke extension): the same durable lifecycle, claim gate and
  # sweeper as a mention wake, keyed by the app's client_invocation_id.
  # Existing rows are mentions. The check constraint keeps the two variants
  # from blurring: a mention always has its message and never a key; an
  # invoke always has its key and digest and never a message.
  def change
    add_column :message_dispatches, :kind, :string, null: false, default: "mention"
    add_column :message_dispatches, :client_invocation_id, :string
    add_column :message_dispatches, :request_digest, :string
    change_column_null :message_dispatches, :message_id, true
    add_index :message_dispatches, [ :chat_id, :user_id, :client_invocation_id ], unique: true,
              where: "client_invocation_id IS NOT NULL", name: "index_message_dispatches_on_invocation_identity"
    add_check_constraint :message_dispatches, <<~SQL.squish, name: "message_dispatches_kind_variant"
      (kind = 'mention' AND message_id IS NOT NULL AND client_invocation_id IS NULL AND request_digest IS NULL)
      OR (kind = 'invoke' AND message_id IS NULL AND client_invocation_id IS NOT NULL AND request_digest IS NOT NULL)
    SQL
  end

end
