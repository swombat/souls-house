class AddResponseRequestedAtToAgentRuntimeInteractions < ActiveRecord::Migration[8.1]

  def change
    add_column :agent_runtime_interactions, :response_requested_at, :datetime
  end

end
