class CreateFieldTweets < ActiveRecord::Migration[8.1]

  def change
    # House switch and limits for tweet streams (off by default). The site
    # ceiling starts at zero: house-paid collection stays shut until an admin
    # sets one on purpose.
    add_column :settings, :field_tweets_enabled, :boolean, default: false, null: false
    add_column :settings, :field_tweets_site_monthly_usd_ceiling, :decimal, precision: 10, scale: 4, default: "0", null: false
    add_column :settings, :field_tweets_account_monthly_usd_ceiling, :decimal, precision: 10, scale: 4, default: "1.0", null: false
    add_column :settings, :field_tweets_daily_import_cap, :integer, default: 50, null: false
    add_column :settings, :field_tweets_poll_minutes, :integer, default: 15, null: false
    # Set when the house key itself fails (bad key, no balance): every
    # house-paid source stops until an admin clears it.
    add_column :settings, :field_tweets_house_halted_at, :datetime
    add_column :settings, :field_tweets_house_halt_reason, :string, limit: 300

    # One followed public handle per account (for now). The checkpoint is
    # the end of the last completed search window; the open window (since,
    # until, cursor) is work in progress that survives retries and outages.
    create_table :field_tweet_sources do |t|
      t.references :account, null: false, foreign_key: true, index: { unique: true }
      t.references :created_by, polymorphic: true
      t.string :handle, null: false, limit: 15
      t.boolean :include_replies, null: false, default: true
      t.boolean :include_quotes, null: false, default: true
      t.boolean :include_reposts, null: false, default: false
      t.text :api_key # the account's own TwitterAPI.io key, encrypted; nil means house-paid
      t.decimal :own_monthly_usd_limit, precision: 10, scale: 4, null: false, default: "5.0"
      t.string :state, null: false, default: "active"
      t.string :state_reason, limit: 300
      t.datetime :connected_at, null: false
      t.datetime :checkpoint_at, null: false
      t.datetime :window_since
      t.datetime :window_until
      t.text :window_cursor
      t.integer :window_pages, null: false, default: 0
      t.integer :window_rejected, null: false, default: 0 # returned tweets in the open window that couldn't be read
      t.datetime :gap_since # a stretch that couldn't be collected
      t.datetime :gap_until
      t.datetime :last_success_at
      t.datetime :next_attempt_at
      t.integer :failure_count, null: false, default: 0
      t.datetime :sync_claimed_at
      t.timestamps
    end
    add_index :field_tweet_sources, :next_attempt_at
    add_check_constraint :field_tweet_sources, "state IN ('active', 'paused', 'needs_attention')", name: "field_tweet_sources_state"

    create_table :field_tweets do |t|
      t.references :account, null: false, foreign_key: true, index: false
      t.references :field_tweet_source, foreign_key: { on_delete: :nullify }
      t.string :provider_tweet_id, null: false, limit: 32
      t.string :author_id, limit: 32
      t.string :author_handle, null: false, limit: 15
      t.string :author_name, limit: 100
      t.text :text, null: false
      t.datetime :posted_at, null: false
      t.datetime :fetched_at, null: false
      t.string :url, null: false, limit: 300
      t.boolean :is_reply, null: false, default: false
      t.boolean :is_quote, null: false, default: false
      t.boolean :is_repost, null: false, default: false
      t.string :in_reply_to_tweet_id, limit: 32
      t.string :in_reply_to_handle, limit: 15
      t.string :conversation_id, limit: 32
      t.string :quoted_tweet_id, limit: 32
      t.string :reposted_tweet_id, limit: 32
      t.jsonb :media, null: false, default: []
      t.jsonb :metrics, null: false, default: {}
      t.datetime :metrics_at
      t.jsonb :related, null: false, default: {} # the quoted or reposted tweet: id, author, text (bounded)
      t.string :lang, limit: 16
      t.string :source, null: false, default: "twitterapi.io", limit: 40
      t.datetime :discarded_at
      t.timestamps
    end
    # A discarded tweet keeps its row, so the next poll can't bring it back.
    add_index :field_tweets, [ :account_id, :provider_tweet_id ], unique: true
    add_index :field_tweets, [ :account_id, :posted_at ]
    add_index :field_tweets, [ :account_id, :created_at ]
    add_index :field_tweets, :discarded_at
    add_column :field_tweets, :search_vector, :virtual, type: :tsvector, stored: true, as: <<~SQL.squish
      setweight(to_tsvector('simple'::regconfig, coalesce(author_handle, '') || ' ' || coalesce(author_name, '')), 'A') ||
      setweight(to_tsvector('simple'::regconfig, left(coalesce(text, ''), 30000)), 'C')
    SQL
    add_index :field_tweets, :search_vector, using: :gin

    # Tweets a search returned that aren't in the Field yet because the
    # day's import allowance ran out. Imported oldest first, before any new
    # page is fetched. Normalised attributes only, no provider payload.
    create_table :field_tweet_backlog_items do |t|
      t.references :field_tweet_source, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.string :provider_tweet_id, null: false, limit: 32
      t.datetime :posted_at, null: false
      t.jsonb :attrs, null: false
      t.timestamps
    end
    add_index :field_tweet_backlog_items, [ :field_tweet_source_id, :provider_tweet_id ], unique: true, name: "index_field_tweet_backlog_on_source_and_tweet"
    add_index :field_tweet_backlog_items, [ :field_tweet_source_id, :posted_at ], name: "index_field_tweet_backlog_on_source_and_posted"

    # One paid provider call: reserved before it is made, settled with what
    # it returned. funding: house or own (the account's key). Kept when a
    # source is removed: spend is history.
    create_table :field_tweet_calls do |t|
      t.references :account, null: false, foreign_key: true
      t.bigint :field_tweet_source_id, index: true
      t.string :funding, null: false
      t.string :status, null: false, default: "reserved"
      t.decimal :charge_usd, precision: 14, scale: 8, null: false
      t.integer :returned_count, null: false, default: 0
      t.integer :already_stored_count, null: false, default: 0
      t.integer :queued_count, null: false, default: 0
      t.integer :rejected_count, null: false, default: 0 # returned but unreadable (no id, author or time)
      t.boolean :retry, null: false, default: false
      t.integer :http_status
      t.string :error, limit: 300
      t.timestamps
    end
    add_index :field_tweet_calls, [ :funding, :created_at ]
    add_check_constraint :field_tweet_calls, "charge_usd >= 0", name: "field_tweet_calls_nonnegative_charge"
    add_check_constraint :field_tweet_calls, "status IN ('reserved', 'settled', 'failed', 'uncertain')", name: "field_tweet_calls_status"
    add_check_constraint :field_tweet_calls, "funding IN ('house', 'own')", name: "field_tweet_calls_funding"

    # Tweets carry tags like every other Field item.
    reversible do |direction|
      direction.up do
        remove_check_constraint :field_taggings, name: "field_taggings_taggable_type"
        add_check_constraint :field_taggings, "taggable_type IN ('FieldFile', 'FieldRecording', 'Whiteboard', 'FieldTweet')", name: "field_taggings_taggable_type"
      end
      direction.down do
        remove_check_constraint :field_taggings, name: "field_taggings_taggable_type"
        add_check_constraint :field_taggings, "taggable_type IN ('FieldFile', 'FieldRecording', 'Whiteboard')", name: "field_taggings_taggable_type"
      end
    end
  end

end
