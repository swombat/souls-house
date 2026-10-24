# A room can say what it is for: "Use this room when…", read by residents
# choosing where to start a conversation (Daniel, 2026-10-20, GJPPaJ).
class AddDescriptionToRooms < ActiveRecord::Migration[8.1]

  def change
    add_column :rooms, :description, :string, limit: 280
  end

end
