class AddRuntimeRollStartedAtToAgents < ActiveRecord::Migration[8.1]
  # Set while a host Rebuild recreates this resident's container. Turn
  # admission skips a resident while it is set (its turns wait, they are not
  # cancelled), so the restart no longer needs the house-wide turn gate held
  # for its whole length, and several residents can restart at once.
  def change
    add_column :agents, :runtime_roll_started_at, :datetime
  end
end
