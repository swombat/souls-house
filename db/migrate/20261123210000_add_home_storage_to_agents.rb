# A VM resident's disk use on its card, walked by its runner (Agents::HomeStorage).
# Kept apart from storage_usage, which is the house host's disk: the daily
# walker can't reach a VM's volumes, and the dashboard totals it as host disk.
# home_storage_requested_at is the card's lease for asking either walker (#1111).
class AddHomeStorageToAgents < ActiveRecord::Migration[8.0]

  def change
    add_column :agents, :home_storage, :jsonb, default: {}, null: false
    add_column :agents, :home_storage_requested_at, :datetime
  end

end
