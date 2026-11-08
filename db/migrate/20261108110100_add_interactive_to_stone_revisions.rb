class AddInteractiveToStoneRevisions < ActiveRecord::Migration[8.0]

  def change
    add_column :stone_revisions, :interactive, :boolean, default: false, null: false
  end

end
