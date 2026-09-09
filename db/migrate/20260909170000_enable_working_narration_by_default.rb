class EnableWorkingNarrationByDefault < ActiveRecord::Migration[8.1]

  def up
    change_column_default :agents, :share_working_narration, from: false, to: true
    # Explicitly authorized rollout: existing false values are treated as the
    # old default, not as recorded opt-outs. Do not change historical run consent.
    execute "UPDATE agents SET share_working_narration = TRUE WHERE share_working_narration = FALSE"
  end

  def down
    # Restoring the old default must not undo choices made since rollout.
    change_column_default :agents, :share_working_narration, from: true, to: false
  end

end
