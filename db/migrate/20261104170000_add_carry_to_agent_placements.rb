class AddCarryToAgentPlacements < ActiveRecord::Migration[8.1]

  # A moving resident's carry (#426 slice 3C, checkpoint 2): the restic
  # snapshot of its stopped house chaos and state volumes, bound to its uuid,
  # generation and runtime image, with an entry count and shape digest per
  # volume. Never a file name. Whether a server restored it is the
  # restore_carry command of the placement's current generation.
  def change
    add_column :agent_placements, :carry, :jsonb
  end

end
