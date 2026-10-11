require "test_helper"
require "webmock/minitest"

module Api
  module V1
    class XPostsControllerTest < ActionDispatch::IntegrationTest

      TWEETS_URL = "https://api.x.com/2/tweets".freeze

      setup do
        @user = users(:confirmed_user)
        @agent = agents(:research_assistant)
        @api_key = ApiKey.generate_for(@user, name: "Resident X", agent: @agent)
        @integration = XIntegration.create!(
          account: @agent.account, enabled: true, x_username: "househandle",
          access_token: "live-token", refresh_token: "refresh-1", token_expires_at: 2.hours.from_now
        )
      end

      test "posts and returns the tweet id and URL" do
        stub_request(:post, TWEETS_URL).to_return(status: 201, body: { data: { id: "777" } }.to_json)

        post_x(text: "Hello", key: "k1")

        assert_response :created
        json = JSON.parse(response.body)
        assert_equal "posted", json["status"]
        assert_equal "777", json["tweet_id"]
        assert_equal "https://x.com/househandle/status/777", json["url"]
        assert_equal @agent, TweetLog.last.agent
      end

      test "a repeated key answers 200 with the same post and does not call X again" do
        stub = stub_request(:post, TWEETS_URL).to_return(status: 201, body: { data: { id: "778" } }.to_json)

        post_x(text: "Hello", key: "k1")
        post_x(text: "Hello", key: "k1")

        assert_response :ok
        assert JSON.parse(response.body)["replayed"]
        assert_requested stub, times: 1
      end

      test "requires an Idempotency-Key" do
        post_x(text: "Hello", key: nil)

        assert_response :bad_request
        assert_equal "idempotency_key_required", JSON.parse(response.body)["code"]
      end

      test "posting switched off is 403 and nothing is sent" do
        @integration.update!(enabled: false)

        post_x(text: "Hello", key: "k1")

        assert_response :forbidden
        assert_not_requested :post, TWEETS_URL
      end

      test "empty and over-length text are 422" do
        post_x(text: "  ", key: "k1")
        assert_response :unprocessable_entity

        post_x(text: "字" * 141, key: "k2")
        assert_response :unprocessable_entity
        assert_equal "text_too_long", JSON.parse(response.body)["code"]
      end

      test "an account_id parameter cannot point the post at another account" do
        other_account = agents(:other_account_agent).account
        @integration.update!(enabled: false)
        XIntegration.create!(account: other_account, enabled: true, access_token: "other", refresh_token: "r", token_expires_at: 2.hours.from_now)

        post_x(text: "Hello", key: "k1", extra: { account_id: other_account.to_param })

        assert_response :forbidden
        assert_not_requested :post, TWEETS_URL
      end

      test "an unknown outcome is 504 first, 409 on retry, and can be resolved" do
        stub = stub_request(:post, TWEETS_URL).to_raise(Net::ReadTimeout)

        post_x(text: "Maybe", key: "k1")
        assert_response :gateway_timeout
        id = JSON.parse(response.body)["id"]
        assert_equal "outcome_unknown", JSON.parse(response.body)["status"]

        post_x(text: "Maybe", key: "k1")
        assert_response :conflict
        assert_requested stub, times: 1

        patch api_v1_x_post_url(id),
          params: { resolution: "posted", tweet_url: "https://x.com/househandle/status/9001" },
          headers: auth_headers, as: :json
        assert_response :ok
        assert_equal "resolved_posted", JSON.parse(response.body)["status"]
        assert_equal "9001", JSON.parse(response.body)["tweet_id"]
      end

      test "a resident cannot resolve another account's post" do
        other_agent = agents(:other_account_agent)
        other = XIntegration.create!(account: other_agent.account, access_token: "o", refresh_token: "r")
        log = other.tweet_logs.create!(agent: other_agent, text: "t", status: "outcome_unknown")

        patch api_v1_x_post_url(log.to_param), params: { resolution: "not_posted" }, headers: auth_headers, as: :json

        assert_response :not_found
        assert_equal "outcome_unknown", log.reload.status
      end

      test "user-scoped keys cannot post" do
        user_key = ApiKey.generate_for(@user, name: "User X")

        post api_v1_x_posts_url, params: { text: "Hi" },
          headers: { "Authorization" => "Bearer #{user_key.raw_token}", "Idempotency-Key" => "k1" }, as: :json

        assert_response :forbidden
      end

      private

      def auth_headers
        { "Authorization" => "Bearer #{@api_key.raw_token}" }
      end

      def post_x(text:, key:, extra: {})
        headers = auth_headers
        headers["Idempotency-Key"] = key if key
        post api_v1_x_posts_url, params: { text: }.merge(extra), headers:, as: :json
      end

    end
  end
end
