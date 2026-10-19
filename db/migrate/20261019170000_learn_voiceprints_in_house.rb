# Field voiceprints slices C and D (docs/2026-10-19-field-voiceprints-in-house.md):
# prints are learned in the house from people's namings, and matched in the
# house. Recognition is on by default (Daniel, 2026-10-19, KJkkdJ: "should
# just be on"); a Field can still switch it off on its Voices page.
#
# The pyannote path never ran in production (0 prints, 0 enrolments, 0
# identifications on 2026-10-19), so its tables go and field_voiceprints is
# reshaped rather than migrated.
class LearnVoiceprintsInHouse < ActiveRecord::Migration[8.1]

  def up
    change_column_default :accounts, :recognise_voices, from: false, to: true
    execute "UPDATE accounts SET recognise_voices = TRUE"

    add_column :field_voices, :remember, :boolean, default: true, null: false
    add_column :field_voices, :learning_generation, :bigint, default: 0, null: false

    create_table :field_voice_samples do |t|
      t.references :account, null: false, foreign_key: true
      t.references :field_voice, null: false, foreign_key: true, index: false
      t.references :field_recording_speaker, null: false, foreign_key: true
      t.bigint :field_recording_id, null: false
      t.text :embedding, null: false
      t.integer :speech_ms, null: false
      t.string :profile, null: false
      t.string :label_origin, null: false
      t.boolean :eligible, null: false, default: false
      t.timestamps
    end
    add_index :field_voice_samples, %i[field_voice_id field_recording_speaker_id], unique: true,
      name: "index_field_voice_samples_on_voice_and_speaker"
    add_index :field_voice_samples, :field_recording_id

    # An unnamed speaker's embedding, kept so matching again (after a print
    # changes) doesn't re-embed every recording. Encrypted, never serialised,
    # cleared whenever the speaker's lines change or a person decides about
    # them, and by Forget all voices.
    add_column :field_recording_speakers, :probe_embedding, :text
    add_column :field_recording_speakers, :probe_profile, :string
    # Bumped by Forget all (and the restore reset): a matching job that was
    # embedding when it happened keeps no probe and makes no guess.
    add_column :accounts, :field_probe_generation, :bigint, default: 0, null: false

    execute "DELETE FROM field_voiceprints"
    remove_reference :field_voiceprints, :sample_recording, index: true
    remove_reference :field_voiceprints, :consented_by, polymorphic: true, index: true
    remove_column :field_voiceprints, :sample_ms
    remove_column :field_voiceprints, :consented_at
    remove_column :field_voiceprints, :consent_text_version
    remove_column :field_voiceprints, :vendor
    add_column :field_voiceprints, :engine, :string, default: "ecapa", null: false
    add_column :field_voiceprints, :profile, :string, null: false
    add_column :field_voiceprints, :sample_count, :integer, default: 0, null: false
    add_column :field_voiceprints, :recording_count, :integer, default: 0, null: false
    add_column :field_voiceprints, :speech_ms, :integer, default: 0, null: false
    add_column :field_voiceprints, :sample_digest, :string, null: false
    add_column :field_voiceprints, :validated_digest, :string
    add_column :field_voiceprints, :validated, :boolean, default: false, null: false
    add_column :field_voiceprints, :validation, :jsonb, default: {}, null: false

    drop_table :field_voice_enrolments
    drop_table :field_recording_identifications

    # Slice A's writer cutover (spec §11): learning refuses to start until it
    # is recorded, so namings that may have come from an API key never train.
    # In production slice A's deploy (cb6ee669) finished at 11:57:25 UTC on
    # 2026-10-19, when the last old writer stopped; the first naming recorded
    # as human after it is 12:36 UTC, and none came before it. Recorded here
    # so learning can start on deploy; `field:mark_unproven_namings_unknown`
    # records a later time if it is ever run again.
    add_column :settings, :field_naming_cutover_at, :datetime
    execute "UPDATE settings SET field_naming_cutover_at = '2026-10-19 11:57:25'" if Rails.env.production?
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end

end
