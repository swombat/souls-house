# A site admin's explicit grant of the house X app to an account that has no
# site admin among its members (accounts with one use it automatically).
class AddXPostingHouseAppToAccounts < ActiveRecord::Migration[8.1]

  def change
    add_column :accounts, :x_posting_house_app, :boolean, default: false, null: false
  end

end
