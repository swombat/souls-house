# An archived room keeps its conversations but leaves the switcher and every
# place a conversation can be put (Room#archived?).
class AddArchivedAtToRooms < ActiveRecord::Migration[8.1]

  def change
    add_column :rooms, :archived_at, :datetime
  end

end
