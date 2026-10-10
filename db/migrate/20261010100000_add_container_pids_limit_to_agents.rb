# A ceiling on processes (and threads: the pids controller counts both) in a
# resident's container, next to container_memory_mb. On 10 Oct 2026 a vite
# fork loop reached 177 copies and held Lume's container at its memory limit
# for three hours; a pids ceiling makes a loop like that fail on fork instead.
# Applies when a container is (re)created.
class AddContainerPidsLimitToAgents < ActiveRecord::Migration[8.1]

  def change
    add_column :agents, :container_pids_limit, :integer, default: 4096, null: false
  end

end
