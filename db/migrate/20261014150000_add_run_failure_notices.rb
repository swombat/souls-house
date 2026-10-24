class AddRunFailureNotices < ActiveRecord::Migration[8.1]

  def change
    add_reference :agent_runtime_interactions, :failure_notice_message,
      foreign_key: { to_table: :messages, on_delete: :nullify }, index: { unique: true }
    add_column :messages, :notice_link, :jsonb
  end

end
