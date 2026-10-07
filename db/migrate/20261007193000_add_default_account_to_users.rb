class AddDefaultAccountToUsers < ActiveRecord::Migration[8.1]
  def change
    add_reference :users, :default_account, null: true,
      foreign_key: { to_table: :accounts, on_delete: :nullify }
  end
end
