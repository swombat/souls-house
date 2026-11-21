# A backup's claim on the pause it is about to take (YEDvGJ, 21 Nov 2026).
# Written, committed, before `docker pause`, and bound to the exact container
# id, so a backup whose worker is killed while it holds the pause leaves a
# record that the next backup can recognise as its own kind of pause, and a
# pause with no claim is known not to be a backup's.
class CreateBackupPauseClaims < ActiveRecord::Migration[8.0]
  def change
    create_table :backup_pause_claims do |t|
      t.references :agent, null: false, foreign_key: { on_delete: :cascade }, index: { unique: true }
      t.string :container_id, null: false
      t.string :token, null: false
      t.datetime :created_at, null: false
    end
  end
end
