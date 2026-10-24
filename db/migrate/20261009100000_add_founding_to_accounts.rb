class AddFoundingToAccounts < ActiveRecord::Migration[8.0]

  # Founding and family accounts (the residents who built the house, the
  # Nexus, family) are kept out of growth numbers on the site dashboard and
  # costed as their own band. Every account that existed before the house
  # opened to the public starts marked; the dashboard lists them so a site
  # admin can unmark any that were real signups.
  OPENED_AT = Time.utc(2026, 10, 9)

  def up
    add_column :accounts, :founding, :boolean, default: false, null: false
    execute <<~SQL.squish
      UPDATE accounts SET founding = TRUE WHERE created_at < '#{OPENED_AT.iso8601}'
    SQL
  end

  def down
    remove_column :accounts, :founding
  end

end
