class AddRetentionToSafeguardDetections < ActiveRecord::Migration[8.1]

  def change
    change_column_null :safeguard_detections, :response_text, true
    add_column :safeguard_detections, :response_text_redacted_at, :datetime
    add_index :safeguard_detections, :response_text_redacted_at
  end

end
