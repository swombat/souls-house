# A Field may let a clear voice match name a speaker without a tap (Daniel,
# 2026-10-23, MYnpDj). The speaker keeps the match score it was named on, so
# the transcript page can say "named by voice" and offer "Not them".
class AddAutomaticNamingOfVoices < ActiveRecord::Migration[8.1]

  def change
    add_column :accounts, :auto_name_voices, :boolean, default: true, null: false
    add_column :field_recording_speakers, :auto_named_confidence, :integer
  end

end
