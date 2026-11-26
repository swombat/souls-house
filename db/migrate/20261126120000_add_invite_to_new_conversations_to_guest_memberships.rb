class AddInviteToNewConversationsToGuestMemberships < ActiveRecord::Migration[8.1]

  def change
    add_column :guest_memberships, :invite_to_new_conversations, :boolean, default: false, null: false
  end

end
