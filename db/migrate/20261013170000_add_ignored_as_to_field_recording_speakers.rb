class AddIgnoredAsToFieldRecordingSpeakers < ActiveRecord::Migration[8.1]

  def change
    # Why a person stopped asking for this speaker's name: "noise" (a cough,
    # the room, a mishearing) or "anonymous" (a real person whose identity
    # doesn't matter here). Read only while ignored_at is set.
    add_column :field_recording_speakers, :ignored_as, :string, null: false, default: "noise"
  end

end
