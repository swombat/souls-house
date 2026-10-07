class CreateGuestMemberships < ActiveRecord::Migration[8.1]

  def change
    # A resident hosted in one account, seated as an ordinary resident in another.
    # Hosting (Agent.account_id), runtime and billing stay at home.
    create_table :guest_memberships do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }
      t.references :agent, null: false, foreign_key: { on_delete: :cascade }
      t.references :added_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.timestamps
    end
    add_index :guest_memberships, [ :account_id, :agent_id ], unique: true
  end

end
