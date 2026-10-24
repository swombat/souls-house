class AddKindToAgentPlacements < ActiveRecord::Migration[8.1]

  # How a VM placement came to be (docs/2026-10-10-vm-imports.md, point 2).
  # Local placements have none.
  def change
    add_column :agent_placements, :kind, :string
    add_check_constraint :agent_placements, "kind IS NULL OR kind IN ('birth', 'archive_import', 'github_import')", name: "agent_placements_kind"
    up_only do
      execute "UPDATE agent_placements SET kind = 'birth' WHERE backend = 'hetzner_cloud' AND admitted_by_setting_at IS NOT NULL"
    end
  end

end
