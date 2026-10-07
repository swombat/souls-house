class AddRhythmKindToMessageDispatches < ActiveRecord::Migration[8.1]

  def up
    replace_constraint(%w[mention automatic rhythm])
  end

  def down
    replace_constraint(%w[mention automatic])
  end

  private

  def replace_constraint(kinds)
    remove_check_constraint :message_dispatches, name: "message_dispatches_kind_variant"
    quoted_kinds = kinds.map { |kind| connection.quote(kind) }.join(", ")
    add_check_constraint :message_dispatches, <<~SQL.squish, name: "message_dispatches_kind_variant"
      (kind IN (#{quoted_kinds}) AND message_id IS NOT NULL AND client_invocation_id IS NULL AND request_digest IS NULL)
      OR (kind = 'invoke' AND message_id IS NULL AND client_invocation_id IS NOT NULL AND request_digest IS NOT NULL)
    SQL
  end

end
