# Recordings slice A2 (spec §3, §7): the account-scoped identities that names
# on transcripts refer to. Print-optional; prints arrive in slice C, in their
# own table.
class CreateFieldVoices < ActiveRecord::Migration[8.1]

  def change
    create_table :field_voices do |t|
      t.references :account, null: false, foreign_key: true
      t.string :name, null: false, limit: 100
      t.references :user, foreign_key: { on_delete: :nullify }
      t.references :created_by, polymorphic: true
      t.datetime :discarded_at
      t.timestamps
    end
    add_index :field_voices, "account_id, lower(name)", unique: true, where: "discarded_at IS NULL",
      name: "index_field_voices_unique_kept_name"
    add_index :field_voices, [ :account_id, :user_id ], unique: true, where: "discarded_at IS NULL AND user_id IS NOT NULL",
      name: "index_field_voices_unique_kept_user"

    add_reference :field_recording_speakers, :field_voice, foreign_key: true
    add_column :field_recording_speakers, :naming_source, :string
    add_reference :field_recording_speakers, :named_by, polymorphic: true
    add_column :field_recording_speakers, :named_at, :datetime

    add_column :users, :field_you_hint_dismissed_at, :datetime
  end

end
