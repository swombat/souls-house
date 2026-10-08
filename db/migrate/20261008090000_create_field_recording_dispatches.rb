# Recordings slice A1b (spec §3, §5): one row per vendor dispatch, the stored
# transcript, and one row per diarized speaker.
class CreateFieldRecordingDispatches < ActiveRecord::Migration[8.1]

  def change
    create_table :field_recording_dispatches do |t|
      t.references :field_recording, null: false, foreign_key: true
      t.references :account, null: false, foreign_key: true
      t.bigint :audio_ms, null: false
      t.string :attempt_token, null: false
      t.string :request_id
      t.string :transcription_id
      t.string :outcome, null: false, default: "in_flight"
      t.string :error
      t.datetime :vendor_deleted_at
      t.string :vendor_delete_error
      t.timestamps
    end
    add_index :field_recording_dispatches, :attempt_token, unique: true
    add_index :field_recording_dispatches, :request_id
    add_index :field_recording_dispatches, [ :account_id, :created_at ]

    create_table :field_recording_speakers do |t|
      t.references :field_recording, null: false, foreign_key: true
      t.string :label, null: false
      t.integer :position, null: false
      t.bigint :talk_ms, null: false, default: 0
      t.bigint :clip_start_ms
      t.bigint :clip_end_ms
      t.timestamps
    end
    add_index :field_recording_speakers, [ :field_recording_id, :label ], unique: true

    add_column :field_recordings, :transcript_words, :jsonb
    add_column :field_recordings, :transcript_text, :text
    add_column :field_recordings, :language_code, :string
  end

end
