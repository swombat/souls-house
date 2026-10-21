# A link that lets anyone holding it read one recording's transcript, with no
# account. The token itself is never stored: only its SHA-256, so a database
# read can't hand out working links. expires_at is null for "never expires";
# revoked_at ends a link early.
class CreateFieldRecordingShares < ActiveRecord::Migration[8.1]

  def change
    create_table :field_recording_shares do |t|
      t.references :field_recording, null: false, foreign_key: { on_delete: :cascade }
      t.references :account, null: false, foreign_key: { on_delete: :cascade }
      t.references :created_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.string :token_digest, null: false, limit: 64
      t.datetime :expires_at
      t.datetime :revoked_at
      t.datetime :last_viewed_at
      t.integer :view_count, null: false, default: 0
      t.timestamps
    end
    add_index :field_recording_shares, :token_digest, unique: true
  end

end
