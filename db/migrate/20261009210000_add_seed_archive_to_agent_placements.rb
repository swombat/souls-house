# A VM resident's first home (#246 slice 3). The archive is built once per
# placement and kept, so every retry of seed_home names the same digest and a
# runner that already unpacked it answers "done" instead of refusing.
class AddSeedArchiveToAgentPlacements < ActiveRecord::Migration[8.1]

  def change
    add_column :agent_placements, :seed_sha256, :string
    add_column :agent_placements, :seed_archive, :binary
    add_column :agent_placements, :seeded_at, :datetime
  end

end
