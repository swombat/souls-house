# Tweet streams are paid per account (Daniel, nedPLe JbNavJ, 2026-10-14):
# an account follows handles with its own TwitterAPI.io integration, and the
# house key is a grant a site admin gives to particular accounts, like the
# shared AI credentials. The per-source key moves to that integration (no
# source had one when this ran), the feature is on, and the house-key
# ceiling is the $10/month Daniel confirmed.
class TweetStreamsPerAccountIntegration < ActiveRecord::Migration[8.1]

  def up
    add_column :accounts, :field_tweets_house_key, :boolean, default: false, null: false
    remove_column :field_tweet_sources, :api_key

    change_column_default :settings, :field_tweets_enabled, from: false, to: true
    change_column_default :settings, :field_tweets_site_monthly_usd_ceiling, from: "0.0", to: "10.0"
    execute "UPDATE settings SET field_tweets_enabled = TRUE"
    execute "UPDATE settings SET field_tweets_site_monthly_usd_ceiling = 10 WHERE field_tweets_site_monthly_usd_ceiling = 0"
  end

  def down
    change_column_default :settings, :field_tweets_site_monthly_usd_ceiling, from: "10.0", to: "0.0"
    change_column_default :settings, :field_tweets_enabled, from: true, to: false
    add_column :field_tweet_sources, :api_key, :text
    remove_column :accounts, :field_tweets_house_key
  end

end
