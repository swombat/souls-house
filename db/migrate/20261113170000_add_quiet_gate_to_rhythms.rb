class AddQuietGateToRhythms < ActiveRecord::Migration[8.1]

  def change
    add_column :rhythms, :quiet_gate, :boolean, default: false, null: false
    add_column :rhythms, :quiet_gate_room_ids, :bigint, array: true, default: [], null: false
    add_column :rhythms, :quiet_watermark_message_id, :bigint
  end

end
