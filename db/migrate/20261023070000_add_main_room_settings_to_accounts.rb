# Main is "no room" (chats with a null room_id), so its name and description
# live on the account. A null name means the default, "Main".
class AddMainRoomSettingsToAccounts < ActiveRecord::Migration[8.1]

  def change
    add_column :accounts, :main_room_name, :string
    add_column :accounts, :main_room_description, :text
  end

end
