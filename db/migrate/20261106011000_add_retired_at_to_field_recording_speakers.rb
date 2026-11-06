class AddRetiredAtToFieldRecordingSpeakers < ActiveRecord::Migration[8.1]

  def change
    add_column :field_recording_speakers, :retired_at, :datetime
  end

end
