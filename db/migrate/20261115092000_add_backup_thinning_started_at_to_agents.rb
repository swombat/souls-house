# Set while the house is thinning a VM resident's backup history
# (Backup::VmThinningJob), so no backup is issued into a repository that is
# being pruned, and so an interrupted thinning is found and recovered.
class AddBackupThinningStartedAtToAgents < ActiveRecord::Migration[8.1]

  def change
    add_column :agents, :backup_thinning_started_at, :datetime
  end

end
