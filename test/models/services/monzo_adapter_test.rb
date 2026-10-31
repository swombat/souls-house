require "test_helper"
require "webmock/minitest"

class Services::MonzoAdapterTest < ActiveSupport::TestCase

  TOKEN_URL = Services::MonzoAdapter::TOKEN_URL
  API = Services::MonzoAdapter::API_ORIGIN

  setup do
    @definition = Services::Definition.fetch("monzo")
    @adapter = @definition.adapter
    @credentials = Object.new
    @credentials.define_singleton_method(:dig) do |*keys|
      { [ :monzo, :client_id ] => "monzo-client", [ :monzo, :client_secret ] => "monzo-secret" }[keys]
    end
    @attempt, = ServiceAuthorizationAttempt.begin!(
      account: accounts(:personal_account),
      user: users(:user_1),
      provider: "monzo",
      management_scope: "personal",
      access_profile: "read_only",
      return_path: "/return"
    )
  end

  def with_credentials(&block)
    Rails.application.stub(:credentials, @credentials, &block)
  end

  def monzo_connection(payload)
    accounts(:personal_account).service_connections.create!(
      connected_by_user: users(:user_1),
      provider: "monzo",
      external_subject_id: "user_000monzo",
      management_scope: "personal",
      credential_kind: "oauth2",
      status: "connected",
      credential_payload_hash: payload,
      credential_metadata: { "credential_strategy" => "read_proxy" }
    )
  end

  def fresh_connection
    monzo_connection("access_token" => "good", "refresh_token" => "r1", "expires_at" => 2.hours.from_now.utc.iso8601)
  end

  test "is read-only by construction: the read proxy, never a token" do
    assert_equal "read_proxy", @definition.credential_strategy
    assert_equal %w[read_only], @definition.access_profiles.keys
  end

  test "is listed only when the house has its own Monzo client" do
    assert_not Rails.application.stub(:credentials, Object.new.tap { |c| c.define_singleton_method(:dig) { |*| nil } }) { @definition.available? }
    assert with_credentials { @definition.available? }
  end

  test "readable paths are the GET reads and nothing that writes" do
    %w[accounts balance pots transactions transactions/tx_00008zIcpb1TB4yeIFXMzx ping/whoami].each do |path|
      assert Services::MonzoAdapter.readable_path?(path), "#{path} should be readable"
    end
    %w[
      pots/pot_123/deposit pots/pot_123/withdraw feed attachment/upload attachment/register
      transaction-receipts webhooks oauth2/logout transactions/tx_1/../../pots/pot_1/withdraw
      transactions/ accounts/acc_1 /accounts
    ].push("").each do |path|
      assert_not Services::MonzoAdapter.readable_path?(path), "#{path.inspect} must not be readable"
    end
  end

  test "authorization URL uses Monzo's endpoint and the house's client" do
    url = with_credentials do
      @adapter.authorization_url(@attempt, state: "state-value", redirect_uri: "https://example.test/service_authorizations/callback")
    end
    query = Rack::Utils.parse_query(URI(url).query)

    assert_equal "auth.monzo.com", URI(url).host
    assert_equal "monzo-client", query["client_id"]
    assert_equal "state-value", query["state"]
    assert_equal "code", query["response_type"]
  end

  test "exchanging the code records Monzo's user id without calling the API, which has no permissions yet" do
    token = stub_request(:post, TOKEN_URL)
      .with(body: hash_including("grant_type" => "authorization_code", "code" => "the-code", "client_secret" => "monzo-secret"))
      .to_return(status: 200, body: {
        access_token: "monzo-access", refresh_token: "monzo-refresh", expires_in: 21_600, user_id: "user_000monzo"
      }.to_json)

    result = with_credentials do
      @adapter.exchange_code(code: "the-code", attempt: @attempt, redirect_uri: "https://example.test/cb")
    end

    assert_requested token
    assert_equal "user_000monzo", result[:external_subject_id]
    assert_equal "monzo-refresh", result.dig(:credential_payload, "refresh_token")
    assert_equal "read_proxy", result.dig(:credential_metadata, "credential_strategy")
    assert_not_requested :get, /api\.monzo\.com/
  end

  test "a public client with no refresh token is refused at connect time" do
    stub_request(:post, TOKEN_URL).to_return(status: 200, body: { access_token: "a", expires_in: 21_600, user_id: "u" }.to_json)

    error = assert_raises(Services::MonzoAdapter::Error) do
      with_credentials { @adapter.exchange_code(code: "c", attempt: @attempt, redirect_uri: "https://example.test/cb") }
    end
    assert_match "confidential", error.message
  end

  test "refreshing stores the new refresh token, because refreshing is one-time" do
    connection = monzo_connection("access_token" => "old", "refresh_token" => "r1", "expires_at" => 1.minute.ago.utc.iso8601)
    stub_request(:post, TOKEN_URL)
      .with(body: hash_including("grant_type" => "refresh_token", "refresh_token" => "r1"))
      .to_return(status: 200, body: { access_token: "new", refresh_token: "r2", expires_in: 21_600, user_id: "u" }.to_json)

    assert_equal "new", with_credentials { @adapter.current_access_token(connection) }
    assert_equal "r2", connection.reload.credential_payload_hash["refresh_token"]
  end

  test "a refused refresh token marks the connection for reconnecting, without echoing the response" do
    connection = monzo_connection("access_token" => "old", "refresh_token" => "r1", "expires_at" => 1.minute.ago.utc.iso8601)
    stub_request(:post, TOKEN_URL).to_return(status: 401, body: { code: "unauthorized.bad_refresh_token", message: "r1" }.to_json)

    error = assert_raises(Services::MonzoAdapter::Error) { with_credentials { @adapter.current_access_token(connection) } }
    assert_match "reconnect Monzo", error.message
    assert_no_match "r1", error.message
    assert_equal "reauthorizing", connection.reload.status
  end

  test "a refusal that isn't about the refresh token leaves the connection connected" do
    connection = monzo_connection("access_token" => "old", "refresh_token" => "r1", "expires_at" => 1.minute.ago.utc.iso8601)
    stub_request(:post, TOKEN_URL).to_return(status: 401, body: { code: "unauthorized.bad_client_secret" }.to_json)

    assert_raises(Services::MonzoAdapter::Error) { with_credentials { @adapter.current_access_token(connection) } }
    assert_equal "connected", connection.reload.status
    assert_equal "r1", connection.credential_payload_hash["refresh_token"]
  end

  test "read forwards a GET with the house's token and returns Monzo's answer" do
    connection = fresh_connection
    balance = stub_request(:get, "#{API}/balance?account_id=acc_1")
      .with(headers: { "Authorization" => "Bearer good" })
      .to_return(status: 200, body: { balance: 5000, currency: "GBP" }.to_json)

    result = with_credentials { @adapter.read(connection, path: "balance", query: { "account_id" => "acc_1" }) }

    assert_requested balance
    assert_equal 200, result.status
    assert_equal 5000, JSON.parse(result.body)["balance"]
  end

  test "read refuses a writing path even if a caller skips the check" do
    assert_raises(ArgumentError) do
      with_credentials { @adapter.read(fresh_connection, path: "pots/pot_1/withdraw", query: {}) }
    end
    assert_not_requested :any, /api\.monzo\.com/
  end

  test "an unreachable Monzo is an adapter error" do
    stub_request(:get, "#{API}/accounts").to_timeout

    assert_raises(Services::MonzoAdapter::Error) do
      with_credentials { @adapter.read(fresh_connection, path: "accounts", query: {}) }
    end
  end

  LOGOUT_URL = Services::MonzoAdapter::LOGOUT_URL

  test "logout uses the current token even when the caller holds a stale copy" do
    connection = fresh_connection
    stale = ServiceConnection.find(connection.id)
    stale.credential_payload_hash # loaded before someone else refreshes
    connection.replace_credential_payload_without_reconciliation!(
      "access_token" => "rotated", "refresh_token" => "r2", "expires_at" => 2.hours.from_now.utc.iso8601
    )
    current = stub_request(:post, LOGOUT_URL).with(headers: { "Authorization" => "Bearer rotated" }).to_return(status: 200, body: "{}")

    with_credentials { @adapter.revoke!(stale) }

    assert_requested current
    assert_not_requested :post, LOGOUT_URL, headers: { "Authorization" => "Bearer good" }
  end

  test "logout with an expired access token refreshes first, and keeps the rotated refresh token" do
    connection = monzo_connection("access_token" => "old", "refresh_token" => "r1", "expires_at" => 1.minute.ago.utc.iso8601)
    stub_request(:post, TOKEN_URL).with(body: hash_including("refresh_token" => "r1"))
      .to_return(status: 200, body: { access_token: "new", refresh_token: "r2", expires_in: 21_600 }.to_json)
    logout = stub_request(:post, LOGOUT_URL).with(headers: { "Authorization" => "Bearer new" }).to_return(status: 200, body: "{}")

    with_credentials { @adapter.revoke!(connection) }

    assert_requested logout
    assert_equal "r2", connection.reload.credential_payload_hash["refresh_token"]
  end

  test "a refused logout raises, and a refresh made for it is not rolled back" do
    connection = monzo_connection("access_token" => "old", "refresh_token" => "r1", "expires_at" => 1.minute.ago.utc.iso8601)
    stub_request(:post, TOKEN_URL).to_return(status: 200, body: { access_token: "new", refresh_token: "r2", expires_in: 21_600 }.to_json)
    stub_request(:post, LOGOUT_URL).to_return(status: 401, body: "{}")

    error = assert_raises(Services::MonzoAdapter::Error) { with_credentials { @adapter.revoke!(connection) } }
    assert_match "logout failed (401)", error.message
    assert_equal "r2", connection.reload.credential_payload_hash["refresh_token"]
  end

  test "disconnecting withdraws the house's access even when Monzo refuses the logout" do
    connection = fresh_connection
    stub_request(:post, LOGOUT_URL).to_return(status: 500, body: "")

    with_credentials { connection.disconnect! }

    assert_equal "revoked", connection.reload.status
    assert_empty connection.credential_payload_hash.to_h
  end

  test "reconnecting a connection whose grant Monzo already refuses goes ahead" do
    connection = monzo_connection("access_token" => "old", "refresh_token" => "r1", "expires_at" => 1.minute.ago.utc.iso8601)
    stub_request(:post, TOKEN_URL).to_return(status: 401, body: { code: "unauthorized.bad_refresh_token" }.to_json)

    with_credentials { connection.begin_reauthorization! }

    assert_equal "reauthorizing", connection.reload.status
    assert_not_requested :post, LOGOUT_URL
  end

  test "reconnecting a live connection logs the old grant out first" do
    connection = fresh_connection
    logout = stub_request(:post, LOGOUT_URL).with(headers: { "Authorization" => "Bearer good" }).to_return(status: 200, body: "{}")

    with_credentials { connection.begin_reauthorization! }

    assert_requested logout
    assert_equal "reauthorizing", connection.reload.status
  end

end
