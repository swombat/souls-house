class AddMnemodyneRecallGeneration < ActiveRecord::Migration[8.1]

  def change
    add_column :mnemodyne_vaults, :recall_generation, :integer, null: false, default: 0
  end

end
