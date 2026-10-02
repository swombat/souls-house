class AddPortabilityCustodyToAgents < ActiveRecord::Migration[8.1]

  def change
    add_column :agents, :portability_custody, :jsonb, default: {}, null: false
  end

end
