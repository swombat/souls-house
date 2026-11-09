require "test_helper"
require "webmock/minitest"
require "support/linkedin_test_helpers"

class Services::LinkedinAdapterTest < ActiveSupport::TestCase

  include LinkedinTestHelpers

  setup do
    @definition = Services::Definition.fetch("linkedin")
    @adapter = @definition.adapter
    @account = accounts(:personal_account)
    @user = users(:user_1)
  end

  test "asks for the self-serve posting scopes" do
    attempt, = ServiceAuthorizationAttempt.begin!(
      account: @account, user: @user, provider: "linkedin", management_scope: "personal",
      access_profile: "post", return_path: "/return"
    )
    url = with_linkedin_credentials { @adapter.authorization_url(attempt, state: "s", redirect_uri: "https://example.test/cb") }
    query = Rack::Utils.parse_query(URI(url).query)

    assert_equal "www.linkedin.com", URI(url).host
    assert_equal "openid profile w_member_social", query["scope"]
    assert_equal "li-client", query["client_id"]
  end

  test "exchanges the code, takes the member from userinfo and keeps the 60-day expiry" do
    attempt, = ServiceAuthorizationAttempt.begin!(
      account: @account, user: @user, provider: "linkedin", management_scope: "personal",
      access_profile: "post", return_path: "/return"
    )
    stub_request(:post, Services::LinkedinAdapter::TOKEN_URL)
      .with(body: hash_including("grant_type" => "authorization_code", "code" => "the-code", "client_secret" => "li-secret"))
      .to_return(status: 200, body: { access_token: "fresh", expires_in: 5_184_000, scope: "openid,profile,w_member_social" }.to_json)
    stub_request(:get, Services::LinkedinAdapter::USERINFO_URL)
      .with(headers: { "Authorization" => "Bearer fresh" })
      .to_return(status: 200, body: { sub: "782bbtaQ", name: "Daniel Tenner" }.to_json)

    result = with_linkedin_credentials { @adapter.exchange_code(code: "the-code", attempt:, redirect_uri: "https://example.test/cb") }

    assert_equal "782bbtaQ", result[:external_subject_id]
    assert_equal "Daniel Tenner", result[:external_identity]
    assert_nil result[:match_existing_by], "reconnecting must find the connection by the member, not by who clicked"
    assert_equal "urn:li:person:782bbtaQ", result.dig(:credential_payload, "author_urn")
    assert_in_delta 60.days.from_now, Time.iso8601(result.dig(:credential_payload, "expires_at")), 5
    assert_equal %w[openid profile w_member_social], result.dig(:credential_metadata, "granted_scopes")
    assert_equal "house_poster", result.dig(:credential_metadata, "credential_strategy")
  end

  test "a fresh token is handed out without calling LinkedIn" do
    connection = linkedin_connection(account: @account, user: @user)

    assert_equal "li-access", @adapter.current_access_token(connection)
  end

  test "an ended grant marks the connection for reconnecting and says so in words" do
    ended = 2.days.ago.utc.change(usec: 0)
    connection = linkedin_connection(account: @account, user: @user, payload: { "expires_at" => ended.iso8601 })

    error = assert_raises(Services::LinkedinAdapter::Expired) { @adapter.current_access_token(connection) }

    assert_match(/ended on #{ended.strftime('%-d %b %Y')}/, error.message)
    assert_match(/reconnects LinkedIn from Integrations/, error.message)
    assert_equal "reauthorizing", connection.reload.status
  end

  test "uses a refresh token when LinkedIn gave one" do
    connection = linkedin_connection(account: @account, user: @user, payload: {
      "expires_at" => 1.minute.from_now.utc.iso8601,
      "refresh_token" => "li-refresh",
      "refresh_token_expires_at" => 300.days.from_now.utc.iso8601
    })
    stub_request(:post, Services::LinkedinAdapter::TOKEN_URL)
      .with(body: hash_including("grant_type" => "refresh_token", "refresh_token" => "li-refresh"))
      .to_return(status: 200, body: { access_token: "renewed", expires_in: 5_184_000 }.to_json)

    token = with_linkedin_credentials { @adapter.current_access_token(connection) }

    assert_equal "renewed", token
    payload = connection.reload.credential_payload_hash
    assert_equal "li-refresh", payload["refresh_token"]
    assert_equal "urn:li:person:abc123", payload["author_urn"]
    assert_in_delta 300.days.from_now, @adapter.grant_expires_at(connection), 5
  end

  test "residents get the posting endpoint, never the token" do
    connection = linkedin_connection(account: @account, user: @user)
    credentials = connection.runtime_credentials(agent: nil)

    assert_equal [ "posts_endpoint" ], credentials.keys
    assert credentials["posts_endpoint"].end_with?("/api/v1/linkedin_posts")
  end

  test "is listed only on a house with its own LinkedIn app" do
    Rails.application.credentials.stub(:dig, nil) { assert_not @definition.available? }
    with_linkedin_credentials { assert @definition.available? }
  end

end
