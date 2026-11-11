class AddWorkStatusToChats < ActiveRecord::Migration[8.1]

  def change
    add_column :chats, :work_status, :string
    add_column :chats, :work_status_reason, :text
    add_column :chats, :work_status_since, :datetime
    add_column :chats, :work_status_revision, :integer, default: 0, null: false
  end

end
