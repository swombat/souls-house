# Boat as a second placement backend (slice 2 of resident placement, ePokyY).
#
# A Boat sandbox is named by a string id (bx_ + 8 characters), not Hetzner's
# positive bigint, and has no Hetzner location. So Boat gets its own column
# on the placement and its own purchase table, beside the Hetzner ones rather
# than folded into them: every existing check on provider_server_id and
# location keeps meaning exactly what it meant.
class CreateBoatProcurement < ActiveRecord::Migration[8.0]

  SANDBOX_ID_SQL = "'^bx_[23456789abcdefghjkmnpqrstuvwxyz]{8}$'".freeze
  STATES = %w[planned create_in_flight reconciling provisioned unknown refused needs_review deleting deleted].freeze

  def change
    add_column :agent_placements, :provider_sandbox_id, :string
    add_index :agent_placements, :provider_sandbox_id, unique: true, where: "provider_sandbox_id IS NOT NULL"
    add_check_constraint :agent_placements, "provider_sandbox_id ~ #{SANDBOX_ID_SQL}",
      name: "agent_placements_sandbox_id_shape"
    add_check_constraint :agent_placements, "provider_sandbox_id IS NULL OR provider_server_id IS NULL",
      name: "agent_placements_one_provider_id"

    create_table :boat_procurement_operations do |t|
      t.references :agent_placement, null: false, foreign_key: true, index: false
      t.references :requested_by, null: false, foreign_key: { to_table: :users }
      t.integer :placement_generation, null: false, default: 1
      # Also the create's Idempotency-Key. The create is still sent once:
      # the enrollment token's plaintext lives only in that one request, so
      # no later request could carry the same body. The key is a second
      # guard, not a retry mechanism.
      t.string :public_id, null: false
      t.string :state, null: false, default: "planned"
      t.string :approval_reference, null: false
      t.string :sandbox_size, null: false
      t.string :provider_name, null: false
      t.string :provider_sandbox_id
      t.string :last_error_code
      t.string :review_reason
      t.datetime :create_sent_at
      t.datetime :provisioned_at
      t.datetime :delete_requested_at
      t.datetime :deleted_at
      t.datetime :last_reconciled_at
      t.timestamps

      t.index :public_id, unique: true
      t.index :provider_name, unique: true
      t.index :provider_sandbox_id, unique: true, where: "provider_sandbox_id IS NOT NULL"
      t.index :agent_placement_id, unique: true, where: "state NOT IN ('refused', 'deleted')",
        name: "index_boat_procurement_operations_one_unresolved"
      t.check_constraint "state IN (#{STATES.map { |s| "'#{s}'" }.join(', ')})", name: "boat_procurement_operations_state"
      t.check_constraint "provider_sandbox_id ~ #{SANDBOX_ID_SQL}", name: "boat_procurement_operations_sandbox_id_shape"
      t.check_constraint "placement_generation >= 1", name: "boat_procurement_operations_positive_generation"
    end

    # A Boat runner's enrollment points at its Boat purchase through its own
    # foreign key (procurement_operation_id keeps meaning a Hetzner one), and
    # names the sandbox it must report (from Boat's reserved BOAT_ID).
    # procurement_kind says which identity the runner must prove.
    add_reference :runner_enrollments, :boat_procurement_operation, foreign_key: true, index: false
    add_index :runner_enrollments, :boat_procurement_operation_id, unique: true,
      where: "boat_procurement_operation_id IS NOT NULL"
    add_column :runner_enrollments, :procurement_kind, :string, null: false, default: "hetzner_cloud"
    add_column :runner_enrollments, :expected_provider_sandbox_id, :string
    add_check_constraint :runner_enrollments, "procurement_kind IN ('hetzner_cloud', 'boat')",
      name: "runner_enrollments_procurement_kind"
    add_check_constraint :runner_enrollments,
      "(procurement_kind = 'boat' AND procurement_operation_id IS NULL AND expected_provider_server_id IS NULL) OR " \
      "(procurement_kind = 'hetzner_cloud' AND boat_procurement_operation_id IS NULL AND expected_provider_sandbox_id IS NULL)",
      name: "runner_enrollments_one_provider"
    add_check_constraint :runner_enrollments, "expected_provider_sandbox_id ~ #{SANDBOX_ID_SQL}",
      name: "runner_enrollments_sandbox_id_shape"
  end

end
