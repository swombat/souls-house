# A site admin chooses, on the import screen, whether a GitHub import is made
# on the main server or on its own server (Daniel, JroAMY JpzVVN). Blank means
# the site setting decides, as before, when the import is admitted.
class AddPlacementToGithubResidentImports < ActiveRecord::Migration[8.0]

  def change
    add_column :github_resident_imports, :placement, :string
    add_check_constraint :github_resident_imports, "placement IS NULL OR placement IN ('main_server', 'own_server')",
      name: "github_resident_import_placement"
  end

end
