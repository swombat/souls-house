class AddStandaloneVoiceSamples < ActiveRecord::Migration[8.1]

  def change
    change_column_null :field_voice_samples, :field_recording_speaker_id, true
    change_column_null :field_voice_samples, :field_recording_id, true
    change_column_null :field_voice_samples, :embedding, true
    change_column_null :field_voice_samples, :profile, true

    add_column :field_voice_samples, :content_sha256, :string
    add_column :field_voice_samples, :source_identifier, :string
    add_column :field_voice_samples, :source_sha256, :string
    add_column :field_voice_samples, :source_session, :string
    add_column :field_voice_samples, :start_ms, :integer
    add_column :field_voice_samples, :end_ms, :integer
    add_column :field_voice_samples, :recorded_at, :datetime
    add_column :field_voice_samples, :idempotency_key, :string
    add_column :field_voice_samples, :request_digest, :string
    # A duplicate upload may have its own retry key. Bind those keys to the
    # same immutable request without retaining another copy of the audio.
    add_column :field_voice_samples, :idempotency_receipts, :jsonb, default: {}, null: false
    add_column :field_voice_samples, :removed_at, :datetime
    add_column :field_voice_samples, :excluded, :boolean, default: false, null: false
    add_column :field_voice_samples, :review_generation, :integer, default: 0, null: false
    add_column :field_voice_samples, :confirmed_digest, :string
    add_reference :field_voice_samples, :confirmed_by, foreign_key: { to_table: :users, on_delete: :nullify }
    add_reference :field_voice_samples, :uploaded_by, foreign_key: { to_table: :users, on_delete: :nullify }
    add_column :field_voice_samples, :confirmed_at, :datetime
    add_column :field_voice_samples, :learning_status, :string
    add_column :field_voice_samples, :learning_error, :string

    add_index :field_voice_samples, [ :account_id, :idempotency_key ], unique: true,
      where: "idempotency_key IS NOT NULL", name: "index_voice_samples_on_account_idempotency"
    add_index :field_voice_samples, [ :account_id, :content_sha256 ], unique: true,
      where: "content_sha256 IS NOT NULL AND removed_at IS NULL",
      name: "index_voice_samples_on_account_content"
    add_index :field_voice_samples, [ :account_id, :source_sha256 ]
    add_check_constraint :field_voice_samples,
      "(start_ms IS NULL AND end_ms IS NULL) OR (start_ms IS NOT NULL AND end_ms IS NOT NULL AND start_ms >= 0 AND end_ms > start_ms)",
      name: "voice_sample_source_interval"
  end

end
