class AddPinnedToVisualTags < ActiveRecord::Migration[8.1]

  def up
    add_column :visual_tags, :pinned, :boolean, default: false, null: false
    # Every account has exactly one fixed Pin tag; the index keeps it to one.
    add_index :visual_tags, :account_id, unique: true, where: "pinned",
      name: "index_visual_tags_on_account_id_pinned"

    seed_existing_accounts
  end

  def down
    # Pin tags stay behind as ordinary tags so no conversation loses its selection.
    remove_index :visual_tags, name: "index_visual_tags_on_account_id_pinned"
    remove_column :visual_tags, :pinned
  end

  def seed_existing_accounts
    execute <<~SQL
      INSERT INTO visual_tags (account_id, label, icon, colour, pinned, created_at, updated_at)
      SELECT accounts.id, 'Pin', 'PushPin', 'amber', TRUE, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM accounts
      WHERE NOT EXISTS (
        SELECT 1 FROM visual_tags WHERE visual_tags.account_id = accounts.id AND visual_tags.pinned
      )
    SQL
  end

end
