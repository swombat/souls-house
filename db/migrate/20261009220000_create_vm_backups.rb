class CreateVmBackups < ActiveRecord::Migration[8.1]

  def change
    create_table :vm_backups do |t|
      t.references :agent, null: false, foreign_key: true
      t.references :runner_command, null: false, foreign_key: true, index: { unique: true }
      t.references :agent_backup_snapshot, foreign_key: true
      t.string :checkpoint_digest
      t.string :checkpoint_file_digest, null: false
      t.string :state, null: false, default: "pending"
      t.string :failure_reason
      t.datetime :deadline_at, null: false
      t.datetime :released_at
      t.timestamps
    end
    add_index :vm_backups, :agent_id, unique: true, where: "released_at IS NULL", name: "one_held_vm_backup_per_agent"
  end

end
