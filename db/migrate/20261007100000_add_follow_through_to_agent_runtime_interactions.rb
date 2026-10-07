class AddFollowThroughToAgentRuntimeInteractions < ActiveRecord::Migration[8.1]

  def change
    # The run a follow-through nudge continues. Present only on nudge runs:
    # it is the depth-1 mark (a nudge run never wakes again) and, through the
    # unique index, the guarantee that one run produces at most one nudge.
    add_reference :agent_runtime_interactions, :follow_through_of,
      foreign_key: { to_table: :agent_runtime_interactions, on_delete: :nullify },
      index: { unique: true, where: "follow_through_of_id IS NOT NULL" }
    # Claimed by the one check that judges this run; a retried job finds it set.
    add_column :agent_runtime_interactions, :follow_through_checked_at, :datetime
  end

end
