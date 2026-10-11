require "test_helper"
require "support/field_tweet_helpers"
require "support/api_human_key_helpers"

class Api::V1::Field::TweetsControllerTest < ActionDispatch::IntegrationTest

  include FieldTweetHelpers
  include ApiHumanKeyHelpers

  setup do
    Setting.instance.update!(allow_agents: true)
    @resident = agents(:research_assistant)
    @account = @resident.account
    @headers = resident_headers(users(:user_1), @resident)
    now = Time.current
    @tweet = @account.field_tweets.create!(FieldTweet.attributes_from(tweet_payload(11, at: now - 1.hour, text: "Morning"), fetched_at: now))
    @reply = @account.field_tweets.create!(FieldTweet.attributes_from(tweet_payload(12, at: now, text: "Agreed", "isReply" => true, "inReplyToId" => "9"), fetched_at: now))
  end

  test "a resident lists and reads its account's tweets, newest first, without the provider payload" do
    get api_v1_field_tweets_path, headers: @headers
    assert_response :success
    listed = response.parsed_body["tweets"]
    assert_equal [ @reply.to_param, @tweet.to_param ], listed.map { it["id"] }
    assert_equal [ "reply" ], listed.first["kinds"]
    assert_equal "https://x.com/danielt/status/12", listed.first["url"]
    assert_nil response.parsed_body["next_page"]

    get api_v1_field_tweet_path(@tweet), headers: @headers
    assert_equal "Morning", response.parsed_body.dig("tweet", "text")
  end

  test "tweets are found by search with kind=tweet and can be tagged" do
    get api_v1_field_search_path, params: { query: "agreed", kind: "tweet" }, headers: @headers
    assert_equal [ [ "tweet", @reply.to_param ] ], response.parsed_body["results"].map { [ it["kind"], it["id"] ] }

    patch api_v1_field_tweet_tags_path(@tweet), params: { add: [ "morning" ] }, headers: @headers, as: :json
    assert_response :success
    get api_v1_field_tweets_path, params: { tag: "morning" }, headers: @headers
    assert_equal [ @tweet.to_param ], response.parsed_body["tweets"].map { it["id"] }
  end

  test "a resident can't reach another account's tweets, or delete any" do
    other = accounts(:another_team).field_tweets.create!(FieldTweet.attributes_from(tweet_payload(11, at: Time.current), fetched_at: Time.current))
    get api_v1_field_tweet_path(other), headers: @headers
    assert_response :not_found

    delete api_v1_field_tweet_path(@tweet), headers: @headers
    assert_response :forbidden
    assert @tweet.reload.kept?
  end

  test "a person deletes a tweet, and the stream status never carries the key" do
    user = users(:user_1)
    headers = human_headers(user, @account)
    delete api_v1_field_tweet_path(@tweet), headers: headers
    assert_response :no_content
    assert @tweet.reload.discarded?

    enable_field_tweets
    @account.create_field_tweet_source!(handle: "danielt", api_key: "never-shown")
    get api_v1_field_tweet_stream_path, headers: @headers
    assert_response :success
    assert_equal "danielt", response.parsed_body.dig("source", "handle")
    assert_not_includes response.body, "never-shown"
  end

end
