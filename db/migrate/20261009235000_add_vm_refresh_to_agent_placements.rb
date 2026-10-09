# A VM resident's credential/service refresh (#246 parity, Mira's #270
# review): the restart it queues is tracked to its exact command, holds turn
# admission until it settles, and marks services reconciled only on confirmed
# success, for the revisions it actually carried.
class AddVmRefreshToAgentPlacements < ActiveRecord::Migration[8.1]

  def change
    add_column :agent_placements, :refresh_command_id, :bigint
    add_column :agent_placements, :refresh_requested_at, :datetime
    add_column :agent_placements, :refresh_snapshot, :jsonb
    add_column :agent_placements, :refresh_last_error, :string
  end

end
