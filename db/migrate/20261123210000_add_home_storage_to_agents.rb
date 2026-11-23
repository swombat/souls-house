# Disk use on a resident's card, measured apart from the journal count and on
# a slower clock: a walk of a 100 GB home outlasted the count's budget, so the
# size read "—" forever for the largest homes (jZWPXJ).
class AddHomeStorageToAgents < ActiveRecord::Migration[8.0]

  def change
    add_column :agents, :home_storage, :jsonb, default: {}, null: false
    add_column :agents, :home_storage_requested_at, :datetime
  end

end
