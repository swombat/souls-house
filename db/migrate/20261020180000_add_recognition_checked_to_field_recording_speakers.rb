# A guess from a voice that hasn't passed its held-out check yet is shown as a
# weaker hint ("maybe Anna?") rather than not at all (Daniel, 2026-10-20,
# KJkkdJ: one meeting with 24 speakers got one guess). false marks such a
# hint; true or null (guesses made before this) is a checked guess.
class AddRecognitionCheckedToFieldRecordingSpeakers < ActiveRecord::Migration[8.1]

  def change
    add_column :field_recording_speakers, :recognition_checked, :boolean
  end

end
