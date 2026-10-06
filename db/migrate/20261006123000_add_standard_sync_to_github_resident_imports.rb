class AddStandardSyncToGithubResidentImports < ActiveRecord::Migration[8.1]

  def change
    add_column :github_resident_imports, :sync_strategy, :string, default: "existing", null: false
    add_column :github_resident_imports, :sync_configuration, :jsonb, default: {}, null: false
    add_column :github_resident_imports, :sync_health, :jsonb, default: {}, null: false
    add_check_constraint :github_resident_imports, "sync_strategy IN ('existing', 'standard')",
      name: "github_resident_import_sync_strategy"
  end

end
