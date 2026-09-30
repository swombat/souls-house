class AddAutomaticKindToMessageDispatches < ActiveRecord::Migration[8.0]

  # The sole-resident automatic wake (#94 B, integrated with master's
  # automatic response) is a dispatch bound to its message like a mention,
  # but not a mention: the public contract never presents it as one.
  def up
    remove_check_constraint :message_dispatches, name: "message_dispatches_kind_variant"
    add_check_constraint :message_dispatches, <<~SQL.squish, name: "message_dispatches_kind_variant"
      (kind IN ('mention', 'automatic') AND message_id IS NOT NULL AND client_invocation_id IS NULL AND request_digest IS NULL)
      OR (kind = 'invoke' AND message_id IS NULL AND client_invocation_id IS NOT NULL AND request_digest IS NOT NULL)
    SQL
  end

  def down
    remove_check_constraint :message_dispatches, name: "message_dispatches_kind_variant"
    add_check_constraint :message_dispatches, <<~SQL.squish, name: "message_dispatches_kind_variant"
      (kind = 'mention' AND message_id IS NOT NULL AND client_invocation_id IS NULL AND request_digest IS NULL)
      OR (kind = 'invoke' AND message_id IS NULL AND client_invocation_id IS NOT NULL AND request_digest IS NOT NULL)
    SQL
  end

end
