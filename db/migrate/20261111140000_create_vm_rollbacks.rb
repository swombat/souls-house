# One attempt to bring a resident back from its server to the house (#426
# 3C rollback wiring). The attempt's reserved generation and phase survive
# job retries, so a retry continues the attempt instead of reserving again
# or repeating a committed swap. source keeps the exact server this resident
# ran on (placement server id, location, procurement operation and enrollment
# ids), captured before the placement switch clears those fields: the later
# VM release targets that server and nothing else. recovery is the receipt
# that the resident's container was recreated on this swap's volumes.
class CreateVmRollbacks < ActiveRecord::Migration[8.1]

  def change
    create_table :vm_rollbacks do |t|
      t.references :agent, null: false, foreign_key: true, index: false
      t.references :agent_placement, null: false, foreign_key: true
      t.references :requested_by, foreign_key: { to_table: :users }
      t.integer :generation, null: false
      t.string :phase, null: false, default: "stopping"
      t.bigint :stop_command_id
      t.bigint :snapshot_command_id
      t.jsonb :source, null: false, default: {}
      t.string :swap_token
      t.jsonb :volume_map
      t.jsonb :recovery
      t.text :error
      t.timestamps
    end
    add_index :vm_rollbacks, [ :agent_id, :generation ], unique: true
    add_index :vm_rollbacks, :agent_id, unique: true, where: "phase IN ('stopping', 'snapshotting', 'restoring', 'committed')",
      name: "index_vm_rollbacks_one_open_per_agent"
  end

end
