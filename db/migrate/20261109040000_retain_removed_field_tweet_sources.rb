class RetainRemovedFieldTweetSources < ActiveRecord::Migration[8.1]

  def up
    add_column :field_tweet_sources, :removed_at, :datetime
    remove_index :field_tweet_sources, :account_id
    add_index :field_tweet_sources, :account_id, unique: true, where: "removed_at IS NULL"
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Retained follow history may contain multiple sources per account"
  end

end
