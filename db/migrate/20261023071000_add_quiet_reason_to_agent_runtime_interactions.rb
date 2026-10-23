# A resident's own, room-visible account of why a run ended without a reply.
# Submitted explicitly through the quiet-reason API; never extracted from stdout.
class AddQuietReasonToAgentRuntimeInteractions < ActiveRecord::Migration[8.1]

  def change
    add_column :agent_runtime_interactions, :quiet_reason, :text
    add_column :agent_runtime_interactions, :quiet_reason_at, :datetime
  end

end
