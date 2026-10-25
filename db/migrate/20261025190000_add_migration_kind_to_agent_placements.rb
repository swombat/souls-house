class AddMigrationKindToAgentPlacements < ActiveRecord::Migration[8.1]

  # #426: an existing house resident moving to its own server. While it is
  # staged or provisioning, the resident's runtime_ready_at is kept here and
  # cleared on the agent, so every gate a birth has (no turn before the first
  # verified backup) applies to it unchanged; Return to house puts it back.
  def change
    add_column :agent_placements, :house_runtime_ready_at, :datetime
    remove_check_constraint :agent_placements, "kind IS NULL OR kind IN ('birth', 'archive_import', 'github_import')",
      name: "agent_placements_kind"
    add_check_constraint :agent_placements, "kind IS NULL OR kind IN ('birth', 'archive_import', 'github_import', 'migration')",
      name: "agent_placements_kind"
  end

end
