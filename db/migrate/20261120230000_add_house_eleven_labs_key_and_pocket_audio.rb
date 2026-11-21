# The house's ElevenLabs key for an account without its own, as a Site Admin
# switch per account (Daniel, YEDPGJ JBVDmo: Nexus may use it "to run the
# voice on the back end"). Off for every account until turned on.
#
# speech_charges: one row per ElevenLabs render, with the key it ran on, so
# use of the house key can be priced per account later. No text, no key.
#
# companion_devices: the last reply a pocket device was sent, so its voice
# can follow as an "audio" message once rendered, and be fetched again
# after a reconnect.
class AddHouseElevenLabsKeyAndPocketAudio < ActiveRecord::Migration[8.0]

  def change
    add_column :accounts, :house_eleven_labs_key, :boolean, null: false, default: false

    create_table :speech_charges do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }
      t.references :agent, foreign_key: { on_delete: :nullify }
      t.references :message, foreign_key: { on_delete: :nullify }
      t.string :surface, limit: 16, null: false
      t.string :key_source, limit: 16, null: false
      t.integer :characters, null: false
      t.timestamps
    end
    add_index :speech_charges, %i[account_id key_source created_at], name: "index_speech_charges_on_account_key_source_created"

    add_column :companion_devices, :pocket_reply_message_id, :bigint
    add_column :companion_devices, :pocket_reply_submission_id, :bigint
    add_column :companion_devices, :pocket_replied_at, :datetime
  end

end
