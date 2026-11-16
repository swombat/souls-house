# A resident's backups are its only versioned history (Daniel, 2026-11-16,
# eRyZBY: "This is their versioned history ... so keep it"). So the default is
# to keep every backup: nothing is removed by age. A resident whose home is
# versioned somewhere else can have this turned off, and is then thinned to
# its keep rules (backup_keep_daily, _weekly, _monthly).
#
# This does not change Backup::Fit: a resident whose backups pass its backup
# space still loses the oldest ones to fit.
class AddBackupKeepAllToAgents < ActiveRecord::Migration[8.1]

  def change
    add_column :agents, :backup_keep_all, :boolean, null: false, default: true
  end

end
