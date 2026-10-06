class AddSubagentSettingsToAgents < ActiveRecord::Migration[8.1]

  def change
    add_column :agents, :subagents_enabled, :boolean, default: false, null: false
    add_column :agents, :subagent_models, :jsonb, default: [], null: false
    add_column :agents, :subagents_policy_changed_at, :datetime
  end

end
