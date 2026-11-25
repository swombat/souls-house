# An account's practices: standing one-line conventions about how the account
# works ("Finished threads get the done tag"), read by every resident and guest
# on each wake in that account. Lines are ordered by position (1..n, kept
# dense by AccountPractice under a lock on the account row).
class CreateAccountPractices < ActiveRecord::Migration[8.1]

  def change
    create_table :account_practices do |t|
      t.references :account, null: false, foreign_key: true, index: false
      t.string :text, null: false
      t.integer :position, null: false
      t.references :updated_by_user, foreign_key: { to_table: :users, on_delete: :nullify }
      t.references :updated_by_agent, foreign_key: { to_table: :agents, on_delete: :nullify }
      t.timestamps

      t.index %i[account_id position]
      t.check_constraint "char_length(text) BETWEEN 1 AND 250", name: "account_practices_text_length"
      t.check_constraint "text !~ '[\\r\\n]'", name: "account_practices_one_line"
      t.check_constraint "position >= 1", name: "account_practices_position_positive"
    end
  end

end
