require "test_helper"
require "support/field_tweet_helpers"

class FieldTweetSourcesControllerTest < ActionDispatch::IntegrationTest

  include FieldTweetHelpers
  include ActiveJob::TestHelper

  setup do
    Setting.instance.update!(allow_agents: true)
    enable_field_tweets
    @user = users(:user_1)
    @account = accounts(:personal_account)
    post login_path, params: { email_address: @user.email_address, password: "password123" }
  end

  test "without an integration or a house grant, following says to set one up first" do
    get account_field_path(@account, tab: "tweets")
    stream = inertia_props["tweet_stream"]
    assert_nil stream["funding"]
    assert_equal account_integrations_path(@account, connect: "twitterapi_io"), stream["integration_url"]

    assert_no_enqueued_jobs do
      post account_field_tweet_source_path(@account), params: { field_tweet_source: { handle: "danielt" } }
    end
    assert_nil @account.reload.field_tweet_source
    assert_equal "You need to set up a TwitterAPI.io integration first.", flash[:alert]
  end

  test "with the account's integration a manager follows a handle; the key is never shown" do
    connect_twitterapi_io(@account, "my-secret-key")
    assert_enqueued_with(job: FieldTweets::SyncJob) do
      post account_field_tweet_source_path(@account), params: { field_tweet_source: {
        handle: "@danielt", include_replies: "1", include_quotes: "0", include_reposts: "0", api_key: "ignored-key"
      } }
    end
    assert_redirected_to account_field_path(@account, tab: "tweets")
    source = @account.reload.field_tweet_source
    assert_equal [ "danielt", true, false, false, "own" ], [ source.handle, source.include_replies, source.include_quotes, source.include_reposts, source.funding ]

    get account_field_path(@account, tab: "tweets")
    assert_response :success
    assert_not_includes response.body, "my-secret-key"
    stream = inertia_props["tweet_stream"]
    assert_equal [ "danielt", "own", "own" ], [ stream.dig("source", "handle"), stream.dig("source", "funding"), stream["funding"] ]
  end

  test "an account granted the house key follows without an integration" do
    @account.update!(field_tweets_house_key: true)
    post account_field_tweet_source_path(@account), params: { field_tweet_source: { handle: "danielt" } }
    assert_equal "house", @account.reload.field_tweet_source.funding
  end

  test "only a site admin grants the house key" do
    assert_not @user.is_site_admin?
    patch field_tweets_house_key_admin_account_path(@account), params: { account: { field_tweets_house_key: true } }
    assert_not @account.reload.field_tweets_house_key?

    delete logout_path
    post login_path, params: { email_address: users(:site_admin_user).email_address, password: "password123" }
    patch field_tweets_house_key_admin_account_path(@account), params: { account: { field_tweets_house_key: true } }
    assert @account.reload.field_tweets_house_key?
  end

  test "pause, resume and stop following; tweets already in stay" do
    @account.update!(field_tweets_house_key: true)
    source = @account.create_field_tweet_source!(handle: "danielt")
    tweet = @account.field_tweets.create!(FieldTweet.attributes_from(tweet_payload(1, at: Time.current), fetched_at: Time.current).merge(field_tweet_source: source))

    post pause_account_field_tweet_source_path(@account)
    assert_equal "paused", source.reload.state
    post resume_account_field_tweet_source_path(@account)
    assert_equal "active", source.reload.state

    delete account_field_tweet_source_path(@account)
    assert_nil @account.reload.field_tweet_source
    assert tweet.reload.kept?
  end

  test "someone outside the account can't set up its stream" do
    outsider = User.find(3)
    assert_not @account.manageable_by?(outsider)
    delete logout_path
    post login_path, params: { email_address: outsider.email_address, password: "password123" }

    post account_field_tweet_source_path(@account), params: { field_tweet_source: { handle: "someone" } }
    assert_nil @account.reload.field_tweet_source
  end

  test "nothing to manage while the house has streams off" do
    Setting.instance.update!(field_tweets_enabled: false)
    post account_field_tweet_source_path(@account), params: { field_tweet_source: { handle: "danielt" } }
    assert_response :not_found
    get account_field_path(@account)
    assert_nil inertia_props["tweet_stream"]
  end

  test "deleting a tweet from the page discards it" do
    tweet = @account.field_tweets.create!(FieldTweet.attributes_from(tweet_payload(1, at: Time.current), fetched_at: Time.current))
    delete account_field_tweet_path(@account, tweet)
    assert_redirected_to account_field_path(@account, tab: "tweets")
    assert tweet.reload.discarded?
  end

  test "tweets appear in the Field page's list and tab" do
    @account.field_tweets.create!(FieldTweet.attributes_from(tweet_payload(1, at: Time.current, text: "Hello there"), fetched_at: Time.current))
    get account_field_path(@account, tab: "tweets")
    item = inertia_props["items"].sole
    assert_equal [ "tweet", "Hello there", "danielt" ], item.values_at("kind", "text", "author_handle")
    assert_equal 1, inertia_props.dig("counts", "tweets")
  end

  private

  # This page's props, read fresh from each response.
  def inertia_props
    JSON.parse(Nokogiri::HTML(response.body).at_css("[data-page]")&.[]("data-page") || response.body)["props"]
  end

end
