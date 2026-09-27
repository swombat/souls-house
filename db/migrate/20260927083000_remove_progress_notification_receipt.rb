class RemoveProgressNotificationReceipt < ActiveRecord::Migration[8.0]

  def change
    remove_column :agent_runtime_interactions, :progress_notified_at, :datetime
  end

end
