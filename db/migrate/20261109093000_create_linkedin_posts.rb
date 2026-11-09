# Posts a resident made to a LinkedIn member profile through the house
# (LinkedinPoster). Like tweet_logs: one row per idempotency key, and a post
# whose fate is unknown stays outcome_unknown until someone resolves it.
class CreateLinkedinPosts < ActiveRecord::Migration[8.1]

  def change
    create_table :linkedin_posts do |t|
      t.references :service_connection, null: false, foreign_key: true
      t.references :agent, null: false, foreign_key: true
      t.text :text, null: false
      t.string :media_kind
      t.string :media_filename
      t.string :media_urn
      t.string :idempotency_key, null: false
      t.string :request_digest, null: false
      t.string :status, null: false, default: "pending"
      t.string :post_urn
      t.string :failure_reason
      t.text :error_message
      t.datetime :resolved_at
      t.references :resolved_by_agent, foreign_key: { to_table: :agents }
      t.timestamps
    end
    add_index :linkedin_posts, %i[agent_id idempotency_key], unique: true
    add_index :linkedin_posts, :post_urn, unique: true
    add_index :linkedin_posts, %i[service_connection_id created_at]
  end

end
