# Recordings in the Field, slice A1a (docs/2026-10-08-field-recordings-spec.md
# §3): the recording itself and its allowance reservation. Dispatches,
# speakers and voices arrive with the slices that use them.
class CreateFieldRecordings < ActiveRecord::Migration[8.1]

  def change
    create_table :field_recordings do |t|
      t.references :account, null: false, foreign_key: true
      t.references :uploaded_by, polymorphic: true
      t.string :title, null: false, limit: 200
      t.text :note
      t.integer :expected_speakers
      t.bigint :duration_ms
      t.string :status, null: false, default: "probing"
      t.string :failure_reason
      t.string :attempt_token
      t.integer :dispatch_count, null: false, default: 0
      t.references :retried_from, foreign_key: { to_table: :field_recordings, on_delete: :nullify }
      t.datetime :ready_at
      t.datetime :discarded_at
      t.timestamps
    end
    add_index :field_recordings, [ :account_id, :created_at ]
    add_index :field_recordings, :discarded_at
    add_index :field_recordings, :status

    create_table :field_recording_reservations do |t|
      t.references :account, null: false, foreign_key: true
      t.references :field_recording, null: false, foreign_key: true, index: { unique: true }
      t.bigint :audio_ms, null: false
      t.string :state, null: false, default: "pending"
      t.datetime :reserved_at, null: false
      t.datetime :consumed_at
      t.datetime :released_at
      t.string :release_reason
      t.timestamps
    end
    add_index :field_recording_reservations, [ :account_id, :state, :consumed_at ],
      name: "index_field_recording_reservations_for_usage"

    add_column :accounts, :recording_ms_weekly_limit, :bigint, null: false, default: 72_000_000
  end

end
