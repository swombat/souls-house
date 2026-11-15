# A purchase can now be a spare: a server the house holds with no resident on
# it (eRyZBY). Such a purchase has no placement and no person who asked for
# it. purpose says which kind a row is, and a constraint keeps purpose and
# placement telling the same story. placement_label is what the server's
# placement label was set to at create, for a purchase whose placement has
# changed since (or never existed): deletion and matching check the label.
class AddSpareServers < ActiveRecord::Migration[8.1]

  def change
    change_column_null :cloud_procurement_operations, :agent_placement_id, true
    change_column_null :cloud_procurement_operations, :requested_by_id, true
    add_column :cloud_procurement_operations, :purpose, :string, null: false, default: "placement"
    add_column :cloud_procurement_operations, :placement_label, :string
    add_check_constraint :cloud_procurement_operations,
      "purpose IN ('placement', 'spare', 'move_source')", name: "cloud_procurement_operations_purpose"
    add_check_constraint :cloud_procurement_operations,
      "(purpose = 'placement') = (agent_placement_id IS NOT NULL)",
      name: "cloud_procurement_operations_purpose_matches_placement"
    add_index :cloud_procurement_operations, [ :purpose, :server_type, :state ],
      name: "index_cloud_procurement_operations_on_purpose_type_state"

    add_column :settings, :spare_server_limit, :integer, null: false, default: 0
    add_column :settings, :spare_cx23_target, :integer, null: false, default: 0
    add_column :settings, :spare_cx33_target, :integer, null: false, default: 0
    add_column :settings, :spare_cx43_target, :integer, null: false, default: 0
  end

end
