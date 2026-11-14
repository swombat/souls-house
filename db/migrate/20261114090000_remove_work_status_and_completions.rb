# Reverts #910 and #911 (issue #752): Daniel took the work-status design back (JdwRRj, 14 Nov).
class RemoveWorkStatusAndCompletions < ActiveRecord::Migration[8.1]
  def up
    drop_table :work_completion_permissions, if_exists: true
    drop_table :work_completions, if_exists: true
    remove_column :chats, :work_status, if_exists: true
    remove_column :chats, :work_status_reason, if_exists: true
    remove_column :chats, :work_status_since, if_exists: true
    remove_column :chats, :work_status_revision, if_exists: true
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
