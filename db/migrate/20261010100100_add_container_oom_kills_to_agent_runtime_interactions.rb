# How many processes the kernel OOM-killed in the resident's container during
# a run that ended badly, found afterwards by RuntimeOomCheckJob. Kept as its
# own fact rather than written over error_class/error_message, so a run whose
# outcome later changes (a lost run that turns out to have completed) still
# has the runtime's own error, and stops saying it ran out of memory.
class AddContainerOomKillsToAgentRuntimeInteractions < ActiveRecord::Migration[8.1]

  def change
    add_column :agent_runtime_interactions, :container_oom_kills, :integer
  end

end
