# Inline tweet cards in conversations (JdwnWj). One row per X status id for
# the whole house, fetched once; messages point at it through
# message_tweet_embeds. The shared row knows nothing about which messages or
# conversations referenced it.
class CreateTweetEmbeds < ActiveRecord::Migration[8.1]

  def change
    create_table :tweet_embeds do |t|
      t.string :provider_tweet_id, null: false
      # pending: not fetched yet (or waiting for a retry); fetched: a card;
      # missing: the provider answered and has no such tweet (permanent);
      # failed: gave up after repeated transient failures.
      t.string :state, null: false, default: "pending"
      t.integer :attempts, null: false, default: 0
      t.datetime :next_attempt_at
      t.datetime :claimed_at
      t.string :last_error
      t.string :author_handle
      t.string :author_name
      t.text :text
      t.datetime :posted_at
      t.string :url
      t.jsonb :media, null: false, default: []
      t.jsonb :related, null: false, default: {}
      t.boolean :is_quote, null: false, default: false
      t.boolean :is_reply, null: false, default: false
      t.datetime :fetched_at
      t.timestamps
    end
    add_index :tweet_embeds, :provider_tweet_id, unique: true
    add_index :tweet_embeds, [ :state, :next_attempt_at ]

    create_table :message_tweet_embeds do |t|
      t.references :message, null: false, foreign_key: { on_delete: :cascade }
      t.references :tweet_embed, null: false, foreign_key: true
      t.integer :position, null: false, default: 0
      t.timestamps
    end
    add_index :message_tweet_embeds, [ :message_id, :tweet_embed_id ], unique: true
  end

end
