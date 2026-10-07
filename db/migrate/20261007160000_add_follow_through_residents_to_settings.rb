class AddFollowThroughResidentsToSettings < ActiveRecord::Migration[8.1]

  def change
    add_column :settings, :follow_through_residents, :string, default: "", null: false
  end

end
