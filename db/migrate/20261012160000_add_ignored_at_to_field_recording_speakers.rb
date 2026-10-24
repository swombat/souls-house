class AddIgnoredAtToFieldRecordingSpeakers < ActiveRecord::Migration[8.1]

  def change
    # A person marked this diarized "speaker" as noise, not someone to name:
    # it no longer counts as waiting (the Needs you tab, the "to name" badge).
    add_column :field_recording_speakers, :ignored_at, :datetime
    add_reference :field_recording_speakers, :ignored_by, polymorphic: true, index: false
  end

end
