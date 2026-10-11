# Correcting a transcript's words, so the Field's copy can be the canonical
# one (conversation WjNZVj). A recording's transcript gains a revision; each
# batch of corrections (and each undo) is a row holding the full original
# entries, so an undo restores timings, spacing and speaker labels exactly.
class AddFieldTranscriptCorrections < ActiveRecord::Migration[8.1]

  def change
    add_column :field_recordings, :transcript_revision, :integer, default: 0, null: false

    create_table :field_transcript_corrections do |t|
      t.references :account, null: false, foreign_key: true
      t.references :field_recording, null: false, foreign_key: true
      t.references :corrected_by, polymorphic: true
      t.string :kind, null: false
      t.integer :base_revision, null: false
      t.integer :revision, null: false
      t.jsonb :edits, null: false, default: []
      t.references :undoes, foreign_key: { to_table: :field_transcript_corrections }
      t.datetime :undone_at
      t.timestamps

      t.index %i[field_recording_id revision], unique: true, name: "index_field_transcript_corrections_on_recording_and_revision"
      t.check_constraint "kind IN ('correction', 'undo')", name: "field_transcript_corrections_kind"
    end
  end

end
