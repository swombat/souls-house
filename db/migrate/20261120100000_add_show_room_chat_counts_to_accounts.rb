# Show how many conversations each room holds, in faint text to the left of
# its name in the room menus (Pepe, eKnVvY). Off by default, because it adds
# noise; switched on per account (Daniel, YlXdpB).
class AddShowRoomChatCountsToAccounts < ActiveRecord::Migration[8.0]

  def change
    add_column :accounts, :show_room_chat_counts, :boolean, default: false, null: false
  end

end
