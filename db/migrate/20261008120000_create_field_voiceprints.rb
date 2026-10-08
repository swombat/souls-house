# Recordings slice C (spec §9): recognition behind two gates. Prints live in
# their own table and are destroyed on forget. A voice's print_generation is
# monotonic and survives forget, so no old snapshot can match a later print.
class CreateFieldVoiceprints < ActiveRecord::Migration[8.1]

  def change
    add_column :accounts, :recognise_voices, :boolean, null: false, default: false
    add_column :field_voices, :print_generation, :bigint, null: false, default: 0

    create_table :field_voiceprints do |t|
      t.references :field_voice, null: false, foreign_key: true, index: { unique: true }
      t.references :account, null: false, foreign_key: true
      t.text :print, null: false
      t.bigint :generation, null: false
      t.references :sample_recording, foreign_key: { to_table: :field_recordings, on_delete: :nullify }
      t.integer :sample_ms, null: false
      t.references :consented_by, polymorphic: true
      t.datetime :consented_at, null: false
      t.string :consent_text_version, null: false
      t.string :vendor, null: false, default: "pyannote"
      t.timestamps
    end

    # A pending "remember this voice": the consent, the cut sample and, once
    # the person says "use it", the vendor job. Deleted by forget.
    create_table :field_voice_enrolments do |t|
      t.references :account, null: false, foreign_key: true
      t.references :field_voice, null: false, foreign_key: true
      t.references :field_recording_speaker, null: false, foreign_key: true
      t.bigint :start_generation, null: false
      t.integer :decision_generation, null: false, default: 0
      t.integer :sample_ms, null: false
      t.references :consented_by, polymorphic: true
      t.string :consent_text_version, null: false
      t.string :status, null: false, default: "previewing"
      t.string :vendor_job_id
      t.integer :poll_count, null: false, default: 0
      t.datetime :expires_at, null: false
      t.timestamps
    end

    create_table :field_recording_identifications do |t|
      t.references :field_recording, null: false, foreign_key: true
      t.string :vendor_job_id, null: false
      t.jsonb :snapshot, null: false, default: {}
      t.jsonb :speaker_decisions, null: false, default: {}
      t.string :status, null: false, default: "dispatched"
      t.integer :poll_count, null: false, default: 0
      t.timestamps
    end

    add_reference :field_recording_speakers, :recognised_voice, foreign_key: { to_table: :field_voices, on_delete: :nullify }
    add_column :field_recording_speakers, :recognition_confidence, :integer
    add_column :field_recording_speakers, :recognition_print_generation, :bigint
    add_column :field_recording_speakers, :recognition_decision_generation, :integer
  end

end
