class AddShowUsageInChatToSettings < ActiveRecord::Migration[8.0]

  def change
    add_column :settings, :show_usage_in_chat, :boolean, default: false, null: false
  end

end
