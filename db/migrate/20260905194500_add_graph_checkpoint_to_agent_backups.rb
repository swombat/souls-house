class AddGraphCheckpointToAgentBackups < ActiveRecord::Migration[8.1]

  def change
    add_column :agent_backup_snapshots, :graph_checkpoint_digest, :string
    add_column :agent_backup_snapshots, :graph_schema_version, :integer
  end

end
