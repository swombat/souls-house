class AddStorageUsageToAgents < ActiveRecord::Migration[8.0]

  def change
    add_column :agents, :storage_usage, :jsonb, default: {}, null: false
  end

end
