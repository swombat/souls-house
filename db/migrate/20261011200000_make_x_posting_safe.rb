class MakeXPostingSafe < ActiveRecord::Migration[8.1]

  def change
    add_column :x_integrations, :daily_post_limit, :integer, null: false, default: 20

    change_column_null :tweet_logs, :tweet_id, true
    add_column :tweet_logs, :status, :string, null: false, default: "posted"
    add_column :tweet_logs, :idempotency_key, :string
    add_column :tweet_logs, :request_digest, :string
    add_column :tweet_logs, :reply_to_tweet_id, :string
    add_column :tweet_logs, :failure_reason, :string
    add_column :tweet_logs, :error_message, :text
    add_column :tweet_logs, :resolved_at, :datetime
    add_reference :tweet_logs, :resolved_by_agent, foreign_key: { to_table: :agents }, null: true

    add_index :tweet_logs, [ :agent_id, :idempotency_key ], unique: true,
      where: "idempotency_key IS NOT NULL", name: "index_tweet_logs_on_agent_and_idempotency_key"
    add_index :tweet_logs, [ :x_integration_id, :created_at ]
  end

end
