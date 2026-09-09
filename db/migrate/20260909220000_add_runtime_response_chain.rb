class AddRuntimeResponseChain < ActiveRecord::Migration[8.1]

  def change
    add_column :agent_runtime_interactions, :response_chain_agent_ids, :jsonb, default: [], null: false
    add_column :agent_runtime_interactions, :response_chain_advanced_at, :datetime
  end

end
