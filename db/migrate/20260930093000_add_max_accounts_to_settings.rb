class AddMaxAccountsToSettings < ActiveRecord::Migration[8.1]

  def change
    add_column :settings, :max_accounts, :integer, default: 30, null: false
  end

end
