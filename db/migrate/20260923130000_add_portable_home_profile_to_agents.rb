class AddPortableHomeProfileToAgents < ActiveRecord::Migration[8.1]
  def change
    add_column :agents, :home_profile, :string, default: "house", null: false
    add_column :agents, :portable_home_id, :string
    add_index :agents, :portable_home_id, unique: true
  end
end
