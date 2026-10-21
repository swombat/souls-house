class AddFieldSpeakerSampleReview < ActiveRecord::Migration[8.1]

  def change
    add_column :field_voice_samples, :source_segments, :jsonb
    add_column :field_voice_samples, :source_digest, :string

    add_column :field_recording_speakers, :sample_excluded, :boolean, default: false, null: false
    add_column :field_recording_speakers, :sample_review_generation, :integer, default: 0, null: false
    add_column :field_recording_speakers, :sample_confirmed_digest, :string
    add_reference :field_recording_speakers, :sample_confirmed_by, foreign_key: { to_table: :users, on_delete: :nullify }
    add_column :field_recording_speakers, :sample_confirmed_at, :datetime
    add_column :field_recording_speakers, :sample_learning_status, :string
    add_column :field_recording_speakers, :sample_learning_error, :string
  end

end
