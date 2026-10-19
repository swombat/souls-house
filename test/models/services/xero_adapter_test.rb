require "test_helper"
require "webmock/minitest"

class Services::XeroAdapterTest < ActiveSupport::TestCase

  TOKEN_URL = Services::XeroAdapter::TOKEN_URL
  CONNECTIONS_URL = Services::XeroAdapter::CONNECTIONS_URL
  REVOKE_URL = Services::XeroAdapter::REVOKE_URL

  setup do
    @definition = Services::Definition.fetch("xero")
    @adapter = @definition.adapter
    @credentials = Object.new
    @credentials.define_singleton_method(:dig) do |*keys|
      { [ :xero, :client_id ] => "xero-client", [ :xero, :client_secret ] => "xero-secret" }[keys]
    end
    @attempt, = ServiceAuthorizationAttempt.begin!(
      account: accounts(:personal_account),
      user: users(:user_1),
      provider: "xero",
      management_scope: "personal",
      access_profile: "read_only",
      return_path: "/return"
    )
  end

  def with_credentials(&block)
    Rails.application.stub(:credentials, @credentials, &block)
  end

  def id_token(claims)
    segment = Base64.urlsafe_encode64(claims.to_json, padding: false)
    "header.#{segment}.signature"
  end

  def xero_connection(payload = {}, subject: "xero-user-1", **string_keyed)
    payload = payload.merge(string_keyed.transform_keys(&:to_s))
    accounts(:personal_account).service_connections.create!(
      connected_by_user: users(:user_1),
      provider: "xero",
      external_subject_id: subject,
      management_scope: "personal",
      credential_kind: "oauth2",
      status: "connected",
      credential_payload_hash: payload,
      credential_metadata: { "credential_strategy" => "refresh_broker" }
    )
  end

  test "read only asks for offline access and no write scope; read and write adds the write scopes" do
    read = @definition.scopes_for("read_only")
    write = @definition.scopes_for("read_write")

    assert_equal "read_only", @definition.default_access_profile
    assert_equal "refresh_broker", @definition.credential_strategy
    assert_includes read, "offline_access"
    assert read.drop(4).all? { |scope| scope.end_with?(".read") }, "read_only must not request a write scope"
    assert_includes write, "accounting.invoices"
    assert_includes write, "accounting.contacts"
  end

  test "asks only for granular scopes, which apps created after 2 March 2026 must use" do
    broad = %w[accounting.transactions accounting.transactions.read accounting.reports.read]
    %w[read_only read_write].each do |profile|
      assert_empty @definition.scopes_for(profile) & broad, "#{profile} requests a deprecated broad scope"
    end
  end

  test "authorization URL uses Xero's endpoint, the attempt's scopes and PKCE" do
    url = with_credentials do
      @adapter.authorization_url(@attempt, state: "state-value", redirect_uri: "https://example.test/service_authorizations/callback")
    end
    query = Rack::Utils.parse_query(URI(url).query)

    assert_equal "login.xero.com", URI(url).host
    assert_equal "xero-client", query["client_id"]
    assert_equal "state-value", query["state"]
    assert_equal "S256", query["code_challenge_method"]
    assert_equal @definition.scopes_for("read_only").sort, query["scope"].split.sort
  end

  test "exchanges the code with basic auth and records the user and organisations" do
    token = stub_request(:post, TOKEN_URL)
      .with(basic_auth: %w[xero-client xero-secret], body: hash_including("grant_type" => "authorization_code", "code" => "the-code"))
      .to_return(status: 200, body: {
        access_token: "xero-access", refresh_token: "xero-refresh", expires_in: 1800,
        scope: @definition.scopes_for("read_only").join(" "),
        id_token: id_token(xero_userid: "xero-user-1", sub: "sub-1", email: "person@example.test")
      }.to_json)
    stub_request(:get, CONNECTIONS_URL)
      .with(headers: { "Authorization" => "Bearer xero-access" })
      .to_return(status: 200, body: [
        { id: "c1", tenantId: "tenant-1", tenantType: "ORGANISATION", tenantName: "Acme Ltd" },
        { id: "c2", tenantId: "tenant-2", tenantType: "ORGANISATION", tenantName: "Acme Holdings" }
      ].to_json)

    result = with_credentials do
      @adapter.exchange_code(code: "the-code", attempt: @attempt, redirect_uri: "https://example.test/cb")
    end

    assert_requested token
    assert_equal "xero-user-1", result[:external_subject_id]
    assert_equal "person@example.test", result[:external_identity]
    assert_equal "xero-refresh", result.dig(:credential_payload, "refresh_token")
    assert_equal %w[Acme\ Ltd Acme\ Holdings], result.dig(:credential_metadata, "tenants").map { |t| t["name"] }
    assert_equal "tenant-1", result.dig(:credential_metadata, "tenants", 0, "id")
  end

  test "refuses a grant with no organisation selected" do
    stub_request(:post, TOKEN_URL).to_return(status: 200, body: {
      access_token: "a", refresh_token: "r", expires_in: 1800, id_token: id_token(xero_userid: "u")
    }.to_json)
    stub_request(:get, CONNECTIONS_URL).to_return(status: 200, body: "[]")

    error = assert_raises(Services::XeroAdapter::Error) do
      with_credentials { @adapter.exchange_code(code: "c", attempt: @attempt, redirect_uri: "https://example.test/cb") }
    end
    assert_match "No Xero organisation", error.message
  end

  test "a fresh access token is returned without calling Xero" do
    connection = xero_connection("access_token" => "still-good", "refresh_token" => "r1", "expires_at" => 20.minutes.from_now.utc.iso8601)

    assert_equal "still-good", with_credentials { @adapter.current_access_token(connection) }
    assert_not_requested :post, TOKEN_URL
  end

  test "refreshing stores the rotated refresh token, because the old one is now dead" do
    connection = xero_connection("access_token" => "old", "refresh_token" => "r1", "expires_at" => 1.minute.ago.utc.iso8601)
    stub_request(:post, TOKEN_URL)
      .with(basic_auth: %w[xero-client xero-secret], body: { "grant_type" => "refresh_token", "refresh_token" => "r1" })
      .to_return(status: 200, body: { access_token: "new", refresh_token: "r2", expires_in: 1800 }.to_json)

    assert_equal "new", with_credentials { @adapter.current_access_token(connection) }
    payload = connection.reload.credential_payload_hash
    assert_equal "r2", payload["refresh_token"]
    assert Time.iso8601(payload["expires_at"]) > 25.minutes.from_now
  end

  test "a refresh answer without a new refresh token is an error, not a fallback to the dead one" do
    connection = xero_connection("access_token" => "old", "refresh_token" => "r1", "expires_at" => 1.minute.ago.utc.iso8601)
    stub_request(:post, TOKEN_URL).to_return(status: 200, body: { access_token: "new", expires_in: 1800 }.to_json)

    assert_raises(Services::XeroAdapter::Error) { with_credentials { @adapter.current_access_token(connection) } }
    assert_equal "r1", connection.reload.credential_payload_hash["refresh_token"]
  end

  test "an expired or reused refresh token says to reconnect, without echoing the response" do
    connection = xero_connection("access_token" => "old", "refresh_token" => "r1", "expires_at" => 1.minute.ago.utc.iso8601)
    stub_request(:post, TOKEN_URL).to_return(status: 400, body: { error: "invalid_grant", detail: "r1" }.to_json)

    error = assert_raises(Services::XeroAdapter::Error) { with_credentials { @adapter.current_access_token(connection) } }
    assert_match "reconnect Xero", error.message
    assert_no_match "r1", error.message
    connection.reload
    assert_equal "reauthorizing", connection.status, "a dead grant must show Reconnect needed on the card"
    assert_empty connection.credential_payload_hash.to_h
  end

  test "a network failure during refresh leaves the connection connected" do
    connection = xero_connection("access_token" => "old", "refresh_token" => "r1", "expires_at" => 1.minute.ago.utc.iso8601)
    stub_request(:post, TOKEN_URL).to_return(status: 503, body: "")

    assert_raises(Services::XeroAdapter::Error) { with_credentials { @adapter.current_access_token(connection) } }
    assert_equal "connected", connection.reload.status
    assert_equal "r1", connection.credential_payload_hash["refresh_token"]
  end

  test "a dead-grant mark cannot clear a grant reconnected after the lock is released" do
    connection = xero_connection("access_token" => "old", "refresh_token" => "dead", "expires_at" => 1.minute.ago.utc.iso8601)
    stub_request(:post, TOKEN_URL).to_return(status: 400, body: { error: "invalid_grant" }.to_json)
    # Simulate the person reconnecting in the window between the refresh
    # lock's commit and the error reaching the caller.
    reconnect = -> {
      fresh = ServiceConnection.find(connection.id)
      fresh.update!(status: "connected")
      fresh.replace_credential_payload_without_reconciliation!(
        "access_token" => "a2", "refresh_token" => "new-grant", "expires_at" => 30.minutes.from_now.utc.iso8601)
    }
    connection.define_singleton_method(:with_lock) do |*args, &block|
      result = super(*args, &block)
      reconnect.call
      result
    end

    assert_raises(Services::XeroAdapter::DeadGrant) { with_credentials { @adapter.current_access_token(connection) } }
    reloaded = ServiceConnection.find(connection.id)
    assert_equal "connected", reloaded.status
    assert_equal "new-grant", reloaded.credential_payload_hash["refresh_token"]
  end

  test "a dropped or malformed response is a short adapter error" do
    connection = xero_connection("access_token" => "old", "refresh_token" => "r1", "expires_at" => 1.minute.ago.utc.iso8601)
    [ EOFError, Net::HTTPBadResponse ].each do |failure|
      WebMock.reset!
      stub_request(:post, TOKEN_URL).to_raise(failure)
      error = assert_raises(Services::XeroAdapter::Error) { with_credentials { @adapter.current_access_token(connection) } }
      assert_equal "Xero could not be reached", error.message
      assert_equal "connected", connection.reload.status
    end
  end

  test "the keep-alive sweep carries on past a connection whose refresh fails" do
    first = xero_connection({ "access_token" => "a", "refresh_token" => "drops", "expires_at" => 40.days.ago.utc.iso8601,
      "refreshed_at" => 40.days.ago.utc.iso8601 }, subject: "xero-user-1")
    second = xero_connection({ "access_token" => "b", "refresh_token" => "fine", "expires_at" => 40.days.ago.utc.iso8601,
      "refreshed_at" => 40.days.ago.utc.iso8601 }, subject: "xero-user-2")
    assert first.id < second.id
    stub_request(:post, TOKEN_URL).with(body: hash_including("refresh_token" => "drops")).to_raise(EOFError)
    stub_request(:post, TOKEN_URL).with(body: hash_including("refresh_token" => "fine"))
      .to_return(status: 200, body: { access_token: "b2", refresh_token: "fine2", expires_in: 1800 }.to_json)

    with_credentials { Services::XeroKeepAliveJob.perform_now }

    assert_equal "drops", first.reload.credential_payload_hash["refresh_token"]
    assert_equal "connected", first.status
    assert_equal "fine2", second.reload.credential_payload_hash["refresh_token"]
  end

  test "keep-alive leaves a connection refreshed within 30 days alone" do
    connection = xero_connection("access_token" => "a", "refresh_token" => "r1",
      "expires_at" => 1.day.ago.utc.iso8601, "refreshed_at" => 29.days.ago.utc.iso8601)

    assert_equal false, with_credentials { @adapter.keep_alive!(connection) }
    assert_not_requested :post, TOKEN_URL
  end

  test "keep-alive refreshes a connection idle for 30 days and stores the rotated token" do
    connection = xero_connection("access_token" => "a", "refresh_token" => "r1",
      "expires_at" => 31.days.ago.utc.iso8601, "refreshed_at" => 31.days.ago.utc.iso8601)
    stub_request(:post, TOKEN_URL)
      .with(body: { "grant_type" => "refresh_token", "refresh_token" => "r1" })
      .to_return(status: 200, body: { access_token: "new", refresh_token: "r2", expires_in: 1800 }.to_json)

    assert_equal true, with_credentials { @adapter.keep_alive!(connection) }
    payload = connection.reload.credential_payload_hash
    assert_equal "r2", payload["refresh_token"]
    assert Time.iso8601(payload["refreshed_at"]) > 1.minute.ago
  end

  test "keep-alive treats a connection with no refresh record by its age" do
    connection = xero_connection("access_token" => "a", "refresh_token" => "r1", "expires_at" => 1.day.ago.utc.iso8601)

    assert_equal false, with_credentials { @adapter.keep_alive!(connection) }
    connection.update_columns(created_at: 31.days.ago)
    stub_request(:post, TOKEN_URL).to_return(status: 200, body: { access_token: "n", refresh_token: "r2", expires_in: 1800 }.to_json)
    assert_equal true, with_credentials { @adapter.keep_alive!(connection) }
  end

  test "the keep-alive job marks a dead grant as needing reconnect without raising" do
    dead = xero_connection("access_token" => "a", "refresh_token" => "dead", "expires_at" => 40.days.ago.utc.iso8601,
      "refreshed_at" => 40.days.ago.utc.iso8601)
    stub_request(:post, TOKEN_URL).with(body: hash_including("refresh_token" => "dead"))
      .to_return(status: 400, body: { error: "invalid_grant" }.to_json)

    with_credentials { Services::XeroKeepAliveJob.perform_now }

    assert_equal "reauthorizing", dead.reload.status
  end

  test "an unreachable Xero is a short adapter error" do
    connection = xero_connection("access_token" => "old", "refresh_token" => "r1", "expires_at" => 1.minute.ago.utc.iso8601)
    stub_request(:post, TOKEN_URL).to_timeout

    error = assert_raises(Services::XeroAdapter::Error) { with_credentials { @adapter.current_access_token(connection) } }
    assert_equal "Xero could not be reached", error.message
  end

  test "an unreadable answer is an adapter error" do
    connection = xero_connection("access_token" => "old", "refresh_token" => "r1", "expires_at" => 1.minute.ago.utc.iso8601)
    stub_request(:post, TOKEN_URL).to_return(status: 200, body: "<html>")

    assert_raises(Services::XeroAdapter::Error) { with_credentials { @adapter.current_access_token(connection) } }
  end

  test "disconnecting revokes the refresh token at Xero" do
    connection = xero_connection("access_token" => "a", "refresh_token" => "r1", "expires_at" => 20.minutes.from_now.utc.iso8601)
    revoke = stub_request(:post, REVOKE_URL)
      .with(basic_auth: %w[xero-client xero-secret], body: { "token" => "r1" })
      .to_return(status: 200, body: "")

    with_credentials { @adapter.revoke!(connection) }
    assert_requested revoke
  end

end
