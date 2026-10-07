class CreateCloudProcurementOperations < ActiveRecord::Migration[8.1]

  UNRESOLVED = "state NOT IN ('refused', 'deleted')".freeze

  def change
    create_table :cloud_procurement_operations do |t|
      t.references :agent_placement, null: false, foreign_key: true, index: false
      t.references :requested_by, null: false, foreign_key: { to_table: :users }
      t.string :public_id, null: false
      t.string :state, null: false, default: "planned"
      t.string :approval_reference, null: false
      t.string :location, null: false
      t.string :server_type, null: false
      t.bigint :image_id, null: false
      t.jsonb :ssh_key_ids, null: false, default: []
      t.string :provider_name, null: false
      t.bigint :provider_server_id
      t.bigint :create_action_id
      t.bigint :delete_action_id
      t.string :ipv4
      t.string :ipv6
      t.string :last_error_code
      t.string :review_reason
      t.datetime :create_sent_at
      t.datetime :provisioned_at
      t.datetime :delete_requested_at
      t.datetime :deleted_at
      t.datetime :last_reconciled_at

      t.timestamps
    end

    add_index :cloud_procurement_operations, :public_id, unique: true
    add_index :cloud_procurement_operations, :provider_name, unique: true
    add_index :cloud_procurement_operations, :provider_server_id, unique: true,
      where: "provider_server_id IS NOT NULL"
    # One unresolved purchase per placement, enforced by the database.
    add_index :cloud_procurement_operations, :agent_placement_id, unique: true,
      where: UNRESOLVED, name: "index_cloud_procurement_operations_one_unresolved"
    add_index :cloud_procurement_operations, [ :location, :state ]
    add_check_constraint :cloud_procurement_operations,
      "state IN ('planned', 'create_in_flight', 'reconciling', 'provisioned', 'unknown', 'refused', " \
      "'needs_review', 'deleting', 'deleted')",
      name: "cloud_procurement_operations_state"
    add_check_constraint :cloud_procurement_operations, "provider_server_id > 0",
      name: "cloud_procurement_operations_positive_server_id"
    add_check_constraint :cloud_procurement_operations, "image_id > 0",
      name: "cloud_procurement_operations_positive_image_id"

    add_column :agent_placements, :location, :string
    add_foreign_key :runner_enrollments, :cloud_procurement_operations, column: :procurement_operation_id
  end

end
