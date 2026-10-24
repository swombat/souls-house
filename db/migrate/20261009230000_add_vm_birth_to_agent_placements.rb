# VM births (#246 slice 5). admitted_by_setting_at is the durable record that
# this birth was admitted while "new residents on their own server" was on;
# procurement keys on it and never re-reads the switch. Cleanup intent
# survives everything until the provider confirms nothing is left.
class AddVmBirthToAgentPlacements < ActiveRecord::Migration[8.1]

  def change
    add_column :agent_placements, :admitted_by_setting_at, :datetime
    add_column :agent_placements, :birth_deadline_at, :datetime
    add_column :agent_placements, :birth_requested_by_id, :bigint
    add_column :agent_placements, :first_backup_command_id, :bigint
    add_column :agent_placements, :cleanup_requested_at, :datetime
    add_column :agent_placements, :cleanup_reason, :string
    add_index :agent_placements, :cleanup_requested_at, where: "cleanup_requested_at IS NOT NULL"
  end

end
