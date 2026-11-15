# What a resident's backup repository holds, as last read back from it after
# thinning (Backup::Fit): how many backups, the oldest, the stored size, and
# whether history is being thinned to fit the resident's backup space.
class AddBackupHistoryToAgents < ActiveRecord::Migration[8.1]

  def change
    add_column :agents, :backup_history, :jsonb, null: false, default: {}
  end

end
