class AddProgressMessages < ActiveRecord::Migration[8.0]

  def change
    add_column :messages, :progress_message, :boolean, default: false, null: false
    add_column :messages, :progress_break_after, :boolean, default: false, null: false
    add_column :agent_runtime_interactions, :progress_notified_at, :datetime
  end

end
