class RefineMnemodyneLifecycle < ActiveRecord::Migration[8.1]

  def change
    add_column :mnemodyne_vaults, :charge_decay_rate, :float, default: 0.001, null: false
    add_column :mnemodyne_vaults, :charge_decay_floor, :float, default: 0.1, null: false
    add_column :mnemodyne_vaults, :last_automatic_recall_at, :datetime
    add_column :mnemodyne_vaults, :last_automatic_recall_status, :string
  end

end
