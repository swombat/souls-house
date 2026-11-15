# Audio sent to the transcriber outside a Field recording: composer voice
# notes and Telegram voice and video messages. One row per send. The first
# send of a piece of audio counts against the same 30-day allowance as
# recordings (FieldRecordingReservation.used_ms); a retry of it (retry: true)
# counts only toward the vendor exposure ceiling, from the day it was sent.
class CreateTranscriptionCharges < ActiveRecord::Migration[8.1]

  def change
    create_table :transcription_charges do |t|
      t.references :account, null: false, foreign_key: true
      t.string :source, null: false
      t.string :source_key, null: false
      t.bigint :audio_ms, null: false
      t.boolean :retry, null: false, default: false
      t.timestamps
    end
    add_index :transcription_charges, [ :source, :source_key ], unique: true, where: "retry = false",
      name: "index_transcription_charges_on_first_send"
    add_index :transcription_charges, [ :account_id, :created_at ]
  end

end
