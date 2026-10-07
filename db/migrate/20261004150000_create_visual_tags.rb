class CreateVisualTags < ActiveRecord::Migration[8.1]

  # Keep the migration independent of future model/default changes.
  DEFAULTS = [
    [ "Conversation", "ChatCircle", "slate" ],
    [ "Building", "Wrench", "blue" ],
    [ "Research", "MagnifyingGlass", "teal" ],
    [ "Reflection", "Sparkle", "violet" ],
    [ "Care", "Heart", "rose" ],
    [ "Creative", "Palette", "amber" ],
    [ "Reading", "BookOpen", "indigo" ],
    [ "Plans", "Compass", "green" ],
    [ "Help", "Lifebuoy", "orange" ]
  ].freeze

  def up
    create_table :visual_tags do |t|
      t.references :account, null: false, foreign_key: true
      t.string :label, null: false, limit: 80
      t.string :icon, null: false
      t.string :colour, null: false
      t.timestamps
    end
    add_index :visual_tags, [ :id, :account_id ], unique: true
    add_reference :chats, :visual_tag
    # A composite FK prevents bypassing account ownership through direct SQL.
    # Model destruction clears selections first, so account_id stays non-null.
    add_foreign_key :chats, :visual_tags,
      column: [ :visual_tag_id, :account_id ], primary_key: [ :id, :account_id ]

    seed_existing_accounts
  end

  def down
    remove_foreign_key :chats, :visual_tags
    remove_reference :chats, :visual_tag
    drop_table :visual_tags
  end

  def seed_existing_accounts
    DEFAULTS.each do |label, icon, colour|
      execute <<~SQL
        INSERT INTO visual_tags (account_id, label, icon, colour, created_at, updated_at)
        SELECT id, #{connection.quote(label)}, #{connection.quote(icon)}, #{connection.quote(colour)}, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
        FROM accounts
      SQL
    end
  end

end
