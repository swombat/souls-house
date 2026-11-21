# The bge vectors copied by hand on prod before #858 moved recall to Voyage
# (YZxGbj, 9 Nov 2026; kept on Mira's ask as the way back). It was never in
# schema.rb, so only prod has it, hence if_exists. Checked on 21 Nov: every
# node on voyage-4, 0 missing, 13 vaults recalling ok/empty and none
# unavailable over seven days, and no foreign key points at it. If bge is
# ever needed again, the way back is to re-embed, which took minutes for
# 3,000 nodes; the copied data cannot come back, so down is irreversible.
class DropMnemodyneNodesEmbeddingBackup20261109 < ActiveRecord::Migration[8.0]
  def up
    drop_table :mnemodyne_nodes_embedding_backup_20261109, if_exists: true
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
