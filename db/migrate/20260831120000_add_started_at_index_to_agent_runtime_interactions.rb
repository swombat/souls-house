class AddStartedAtIndexToAgentRuntimeInteractions < ActiveRecord::Migration[8.0]

  def change
    add_index :agent_runtime_interactions, :started_at
  end

end
