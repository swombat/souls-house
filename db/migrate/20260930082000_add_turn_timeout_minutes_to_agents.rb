class AddTurnTimeoutMinutesToAgents < ActiveRecord::Migration[8.1]

  def change
    add_column :agents, :turn_timeout_minutes, :integer, default: 30, null: false
    add_check_constraint :agents, "turn_timeout_minutes BETWEEN 1 AND 1440",
      name: "agents_turn_timeout_minutes_range"
  end

end
