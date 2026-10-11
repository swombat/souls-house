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

  test "a manager follows a handle; collection starts from now and the key is never shown" do
    assert_enqueued_with(job: FieldTweets::SyncJob) do
      post account_field_tweet_source_path(@account), params: { field_tweet_source: {
        handle: "@danielt", include_replies: "1", include_quotes: "0", include_reposts: "0", api_key: "my-secret-key"
      } }
    end
    assert_redirected_to account_field_path(@account, tab: "tweets")
    source = @account.reload.field_tweet_source
    assert_equal [ "danielt", true, false, false, "own" ], [ source.handle, source.include_replies, source.include_quotes, source.include_reposts, source.funding ]

    get account_field_path(@account, tab: "tweets")
    assert_response :success
    assert_not_includes response.body, "my-secret-key"
    stream = inertia_props["tweet_stream"]
    assert_equal "danielt", stream.dig("source", "handle")
    assert_equal true, stream.dig("source", "has_own_key")
  end

  test "an empty key field leaves the key; removing it goes back to the house" do
    source = @account.create_field_tweet_source!(handle: "danielt", api_key: "k1")
    patch account_field_tweet_source_path(@account), params: { field_tweet_source: { api_key: "", include_reposts: "1" } }
    assert_equal [ "k1", true ], [ source.reload.api_key, source.include_reposts ]

    patch account_field_tweet_source_path(@account), params: { field_tweet_source: { remove_api_key: "true" } }
    assert_equal "house", source.reload.funding
  end

  test "a new key resumes a stream stopped for its old one" do
    source = @account.create_field_tweet_source!(handle: "danielt", api_key: "k1")
    source.needs_attention!("refused")
    patch account_field_tweet_source_path(@account), params: { field_tweet_source: { api_key: "k2" } }
    assert_equal [ "active", "k2" ], [ source.reload.state, source.api_key ]
  end

  test "pause, resume and stop following; tweets already in stay" do
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
