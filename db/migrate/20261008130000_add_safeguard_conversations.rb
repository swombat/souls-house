# Safeguard seam in conversations (docs/safeguard-conversations-spec.md).
# The label lives on the message; "outstanding notice" is derived from
# detection rows (notice_acknowledged_at), never a separate pointer.
class AddSafeguardConversations < ActiveRecord::Migration[8.1]

  def change
    add_reference :messages, :safeguard_detection, foreign_key: true, index: { unique: true, where: "safeguard_detection_id IS NOT NULL" }
    add_column :safeguard_detections, :notice_acknowledged_at, :datetime
    add_index :safeguard_detections, [ :channel, :notice_acknowledged_at ],
      where: "notice_acknowledged_at IS NULL AND reclaimed_at IS NULL",
      name: "index_safeguard_detections_outstanding"

    add_column :chat_agents, :safeguard_reset_requested_generation, :integer, null: false, default: 0
    add_column :chat_agents, :safeguard_reset_acknowledged_generation, :integer, null: false, default: 0

    add_column :settings, :safeguard_conversations_enabled, :boolean, null: false, default: false
  end

end
