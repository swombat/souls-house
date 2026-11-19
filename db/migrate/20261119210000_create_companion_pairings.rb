# Pairing with a code (YMamQY): the computer opens a pairing and shows a short
# code; an owner or admin types it on the Computers page and approves. The
# approval creates an ordinary enrollment grant and hands its one-use token to
# the computer, which then enrolls exactly as before.
class CreateCompanionPairings < ActiveRecord::Migration[8.1]

  def change
    create_table :companion_pairings do |t|
      t.string :name, limit: 100, null: false
      t.string :device_request_id, limit: 128, null: false
      t.jsonb :offered_volumes, null: false
      t.string :code_digest, limit: 64, null: false
      t.string :poll_secret_digest, limit: 64, null: false
      t.datetime :expires_at, null: false
      t.references :account, foreign_key: true
      t.references :approved_by_user, foreign_key: { to_table: :users }
      t.references :companion_enrollment_grant, foreign_key: true
      t.text :enrollment_token
      t.datetime :approved_at
      t.timestamps
    end
    add_index :companion_pairings, :code_digest, unique: true
    add_index :companion_pairings, :expires_at
  end

end
