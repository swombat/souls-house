# A line a resident leaves for their next heartbeat (JoXGbY). Written by the
# resident, shown back to them in the next scheduled wake, never posted to a
# conversation. Encrypted at rest and kept out of the agent's JSON.
class AddHeartbeatNoteToAgents < ActiveRecord::Migration[8.0]

  def change
    add_column :agents, :heartbeat_note, :text
  end

end
