# One attempt to move a resident from the server it runs on to another one
# the house already holds (eRyZBY). The row is the move's durable memory:
# which two servers, which snapshot, which provider actions, and how far it
# got. One open move per resident, and a spare is the target of one open
# move at most.
class CreateVmServerMoves < ActiveRecord::Migration[8.1]

  OPEN = "('stopping', 'snapshotting', 'rebuilding', 'verifying', 'reverting')".freeze

  def change
    create_table :vm_server_moves do |t|
      t.references :agent, null: false, foreign_key: true, index: false
      t.references :agent_placement, null: false, foreign_key: true, index: false
      t.references :requested_by, null: false, foreign_key: { to_table: :users }
      t.references :source_operation, null: false, foreign_key: { to_table: :cloud_procurement_operations }, index: false
      t.references :target_operation, null: false, foreign_key: { to_table: :cloud_procurement_operations }, index: false
      t.references :runner_enrollment, null: false, foreign_key: true, index: false
      t.string :public_id, null: false
      t.string :phase, null: false, default: "stopping"
      t.bigint :source_server_id, null: false
      t.bigint :target_server_id, null: false
      t.bigint :snapshot_image_id
      t.bigint :snapshot_action_id
      t.bigint :rebuild_action_id
      t.datetime :phase_started_at, null: false
      t.datetime :stop_requested_at
      t.datetime :poweroff_requested_at
      t.datetime :switched_at
      t.datetime :rebuilt_at
      t.datetime :verified_at
      t.datetime :released_at
      t.string :failure
      t.string :revert_reason
      t.timestamps
    end
    add_index :vm_server_moves, :public_id, unique: true
    add_index :vm_server_moves, :agent_id, unique: true, where: "phase IN #{OPEN}", name: "index_vm_server_moves_one_open_per_agent"
    add_index :vm_server_moves, :target_operation_id, unique: true, where: "phase IN #{OPEN}",
      name: "index_vm_server_moves_one_open_per_target"
    add_index :vm_server_moves, :agent_id
    add_check_constraint :vm_server_moves,
      "phase IN ('stopping', 'snapshotting', 'rebuilding', 'verifying', 'moved', 'reverting', 'reverted', 'released')",
      name: "vm_server_moves_phase"
  end

end
