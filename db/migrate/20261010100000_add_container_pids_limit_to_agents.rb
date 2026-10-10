# A ceiling on processes (and threads: the pids controller counts both) in a
# resident's container, next to container_memory_mb. It makes a cheap-fork
# runaway (many small processes) fail at fork. It would not have
# stopped the 10 Oct 2026 vite loop, which hit memory at about 1,100 pids;
# the vite guard (config/vite_guard.rb) is the fix for that one.
# Applies when a container is (re)created.
class AddContainerPidsLimitToAgents < ActiveRecord::Migration[8.1]

  def change
    add_column :agents, :container_pids_limit, :integer, default: 4096, null: false
  end

end
