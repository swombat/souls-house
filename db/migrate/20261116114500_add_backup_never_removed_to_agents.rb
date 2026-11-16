# Some residents keep every backup without limit (Daniel, 2026-11-16, eRyZBY:
# "For the Nexus gang, we keep everything. For any others, we keep the last X
# days, whatever fits in the plan"). For a resident with this set the house
# removes no backup, neither by age nor to fit its backup space (Backup::Fit).
# Off by default: everyone else keeps as much history as fits.
class AddBackupNeverRemovedToAgents < ActiveRecord::Migration[8.1]

  def change
    add_column :agents, :backup_never_removed, :boolean, null: false, default: false
  end

end
