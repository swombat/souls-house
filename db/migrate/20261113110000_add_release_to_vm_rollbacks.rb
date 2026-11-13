# Releasing the server a rollback left behind (#426 release_vm!). By then the
# placement is the house's again, so the intent and its outcome live on the
# attempt, never on the placement's cleanup fields (VmCleanupJob would retire
# a local placement and take the resident off the house).
class AddReleaseToVmRollbacks < ActiveRecord::Migration[8.1]

  def change
    add_column :vm_rollbacks, :release_requested_at, :datetime
    add_column :vm_rollbacks, :release_reason, :string
    add_reference :vm_rollbacks, :release_requested_by, foreign_key: { to_table: :users }
    add_column :vm_rollbacks, :released_at, :datetime
    add_index :vm_rollbacks, :release_requested_at, where: "released_at IS NULL", name: "index_vm_rollbacks_releasing"
  end

end
