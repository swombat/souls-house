class CompleteMnemodyneCustody < ActiveRecord::Migration[8.1]

  def change
    add_column :mnemodyne_vaults, :erasure_requested_at, :datetime
    add_column :mnemodyne_vaults, :erase_after, :datetime
    add_column :mnemodyne_vaults, :erasure_fingerprint, :string
    add_column :mnemodyne_vaults, :erase_constitutional, :boolean, null: false, default: false
    add_column :agents, :memory_erased_at, :datetime
  end

end
