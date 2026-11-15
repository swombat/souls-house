# Audio sent to the transcriber outside a Field recording: composer voice
# notes and Telegram voice and video messages. One row per piece of audio,
# however many times it is sent, counted against the same 30-day allowance as
# recordings (FieldRecordingReservation.used_ms).
class CreateTranscriptionCharges < ActiveRecord::Migration[8.1]

  def change
    create_table :transcription_charges do |t|
      t.references :account, null: false, foreign_key: true
      t.string :source, null: false
      t.string :source_key, null: false
      t.bigint :audio_ms, null: false
      t.integer :attempts, null: false, default: 1
      t.boolean :estimated, null: false, default: false
      t.timestamps
    end
    add_index :transcription_charges, [ :source, :source_key ], unique: true
    add_index :transcription_charges, [ :account_id, :created_at ]
  end

end
