class AddTitleSweepAttemptsToChats < ActiveRecord::Migration[8.1]

  def change
    add_column :chats, :title_sweep_attempts, :integer, default: 0, null: false
  end

end
