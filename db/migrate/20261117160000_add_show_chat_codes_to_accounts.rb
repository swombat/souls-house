# Show each conversation's code (the last part of its address) under its title,
# with a tap to copy it, so a person can point their residents at a chat
# ("carry on from ewMarJ") from the installed app, which has no address bar
# (Pepe, eVvbpe). Off by default; switched on per account.
class AddShowChatCodesToAccounts < ActiveRecord::Migration[8.0]

  def change
    add_column :accounts, :show_chat_codes, :boolean, default: false, null: false
  end

end
