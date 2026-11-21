# The cutover barrier (eoyXXJ, 21 Nov 2026). A deploy raises a fence before
# it waits for backups and lowers it once the release has switched; a house
# backup checks the fence and writes its pause claim under one advisory lock
# (Backup::DeployFence.serialized), so every claim either comes before the
# fence, where the deploy's wait sees it, or is refused. A claim's
# touched_at is a heartbeat while its backup holds the pause, so the deploy
# can tell a live backup from a dead worker's leftover claim.
class CreateBackupDeployFences < ActiveRecord::Migration[8.0]

  def change
    create_table :backup_deploy_fences do |t|
      t.string :deploy_id, null: false, index: { unique: true }
      t.datetime :raised_at, null: false
      t.datetime :expires_at, null: false
    end
    add_column :backup_pause_claims, :touched_at, :datetime
  end

end
