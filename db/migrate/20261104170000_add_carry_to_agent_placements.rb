class AddCarryToAgentPlacements < ActiveRecord::Migration[8.1]

  # A moving resident's carry (#426 slice 3C, checkpoint 2): the restic
  # snapshot of its stopped house chaos and state volumes, bound to its uuid,
  # generation and runtime image, with an entry count and shape digest per
  # volume. Never a file name. carry_restored_at is set once the server's
  # restore_carry reproduced both digests; the resident starts only after.
  def change
    add_column :agent_placements, :carry, :jsonb
    add_column :agent_placements, :carry_restored_at, :datetime
  end

end
