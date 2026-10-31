require "test_helper"
require "webmock/minitest"

class Services::FreeagentAdapterTest < ActiveSupport::TestCase

  TOKEN_URL = Services::FreeagentAdapter::TOKEN_URL
  USER_URL = Services::FreeagentAdapter::USER_URL
  COMPANY_URL = Services::FreeagentAdapter::COMPANY_URL

  setup do
    @definition = Services::Definition.fetch("freeagent")
    @adapter = @definition.adapter
    @credentials = Object.new
    @credentials.define_singleton_method(:dig) do |*keys|
      { [ :freeagent, :client_id ] => "freeagent-client", [ :freeagent, :client_secret ] => "freeagent-secret" }[keys]
    end
    @attempt, = ServiceAuthorizationAttempt.begin!(
      account: accounts(:personal_account), user: users(:user_1),
      provider: "freeagent", management_scope: "personal",
      access_profile: "user_permissions", return_path: "/return"
    )
  end

  def with_credentials(&block)
    Rails.application.stub(:credentials, @credentials, &block)
  end

  def exchange
    with_credentials { @adapter.exchange_code(code: "the-code", attempt: @attempt, redirect_uri: "https://example.test/cb") }
  end

  def tokens
    { access_token: "synthetic-access", refresh_token: "synthetic-refresh", expires_in: 3600, refresh_token_expires_in: 86400 }
  end

  def stub_exchange(data = tokens)
    stub_request(:post, TOKEN_URL).to_return(status: 200, body: data.to_json)
    stub_user
    stub_company
  end

  def stub_user(data = {})
    stub_request(:get, USER_URL).to_return(status: 200, body: {
      user: { url: "https://api.freeagent.com/v2/users/12", email: "person@example.test", permission_level: 8,
              ni_number: "PRIVATE-NI", tax_reference: "PRIVATE-TAX" }.merge(data)
    }.to_json)
  end

  def stub_company(data = {})
    stub_request(:get, COMPANY_URL).to_return(status: 200, body: {
      company: { id: 34, url: COMPANY_URL, name: "Example Ltd", company_registration_number: "12345678",
                 bank_account: "PRIVATE-BANK" }.merge(data)
    }.to_json)
  end

  def connection(payload = {})
    accounts(:personal_account).service_connections.create!(
      connected_by_user: users(:user_1), provider: "freeagent",
      external_subject_id: '["34","https://api.freeagent.com/v2/users/12"]',
      management_scope: "personal", credential_kind: "oauth2", status: "connected",
      credential_payload_hash: {
        "access_token" => "old-access", "refresh_token" => "old-refresh",
        "expires_at" => 1.minute.ago.utc.iso8601
      }.merge(payload),
      credential_metadata: { "credential_strategy" => "refresh_broker", "granted_scopes" => [] }
    )
  end

  test "authorization is production confidential code flow without invented scope or PKCE" do
    url = with_credentials { @adapter.authorization_url(@attempt, state: "state", redirect_uri: "https://example.test/cb") }
    assert_equal Services::FreeagentAdapter::AUTHORIZE_URL, url.split("?").first
    assert_equal({
      "client_id" => "freeagent-client", "response_type" => "code",
      "state" => "state", "redirect_uri" => "https://example.test/cb"
    }, Rack::Utils.parse_query(URI(url).query))
    assert_equal "user_permissions", @definition.default_access_profile
    assert_empty @definition.scopes_for("user_permissions")
  end

  test "code exchange validates both identities and allowlists safe metadata" do
    stub_exchange
    token = stub_request(:post, TOKEN_URL)
      .with(basic_auth: %w[freeagent-client freeagent-secret],
        headers: { "User-Agent" => Services::FreeagentAdapter::USER_AGENT, "Accept" => "application/json" },
        body: { "grant_type" => "authorization_code", "code" => "the-code", "redirect_uri" => "https://example.test/cb" })
      .to_return(status: 200, body: tokens.to_json)
    result = exchange

    assert_requested token
    [ USER_URL, COMPANY_URL ].each do |url|
      assert_requested :get, url, headers: { "Authorization" => "Bearer synthetic-access", "User-Agent" => Services::FreeagentAdapter::USER_AGENT }
    end
    assert_equal [ "34", "https://api.freeagent.com/v2/users/12" ], JSON.parse(result[:external_subject_id])
    assert_equal "Example Ltd (12345678) — person@example.test", result[:external_identity]
    metadata = result[:credential_metadata]
    assert_equal %w[email permission_level url], metadata["identity"].keys.sort
    assert_equal %w[company_registration_number id name url], metadata["company"].keys.sort
    assert_equal Services::FreeagentAdapter::AUTHORITY_SUMMARY, metadata["authority_summary"]
    assert_empty metadata["granted_scopes"]
    assert_not_includes metadata.to_json, "PRIVATE"
    assert_equal "synthetic-refresh", result.dig(:credential_payload, "refresh_token")
    assert Time.iso8601(result.dig(:credential_payload, "expires_at")) > 59.minutes.from_now
    assert Time.iso8601(result.dig(:credential_payload, "refresh_expires_at")) > 23.hours.from_now
  end

  test "company and user both bind subject even though company URL is constant" do
    stub_exchange
    first = exchange
    stub_company(id: "35")
    second = exchange
    stub_user(url: "https://api.freeagent.com/v2/users/13")
    third = exchange
    assert_not_equal first[:external_subject_id], second[:external_subject_id]
    assert_not_equal second[:external_subject_id], third[:external_subject_id]
    stub_company(company_registration_number: nil)
    assert_equal "Example Ltd — person@example.test", exchange[:external_identity]
  end

  test "initial credentials require nonempty string tokens and positive integral lifetimes" do
    [
      { access_token: nil }, { access_token: {} }, { access_token: "bad\nsecret" },
      { refresh_token: nil }, { refresh_token: "" }, { refresh_token: [] },
      { expires_in: 0 }, { expires_in: -1 }, { expires_in: "secret" }, { expires_in: 1.5 },
      { refresh_token_expires_in: 0 }
    ].each do |invalid|
      stub_exchange(tokens.merge(invalid))
      error = assert_raises(Services::FreeagentAdapter::Error) { exchange }
      assert_not_includes error.message, "secret"
    end
  end

  test "malformed JSON and resource shapes produce sanitized adapter errors" do
    [ "[]", "null", '"secret"', "<secret>" ].each do |body|
      stub_request(:post, TOKEN_URL).to_return(status: 200, body: body)
      error = assert_raises(Services::FreeagentAdapter::Error) { exchange }
      assert_not_includes error.message, "secret"
    end
    [ USER_URL, COMPANY_URL ].each do |url|
      [ "[]", "null", '{"user":[],"company":[]}', '{"user":{},"company":{}}', "<secret>" ].each do |body|
        stub_exchange
        stub_request(:get, url).to_return(status: 200, body: body)
        error = assert_raises(Services::FreeagentAdapter::Error) { exchange }
        assert_not_includes error.message, "secret"
      end
    end
    stub_exchange
    stub_company(id: nil)
    assert_raises(Services::FreeagentAdapter::Error) { exchange }
  end

  test "fresh token is reused and encrypted storage and runtime manifest never reveal broker secrets" do
    record = connection("expires_at" => 30.minutes.from_now.utc.iso8601)
    assert_equal "old-access", with_credentials { @adapter.current_access_token(record) }
    assert_not_requested :post, TOKEN_URL
    # Query the raw database value, not an encrypted attribute that Rails decrypts.
    ciphertext = ServiceConnection.connection.select_value("SELECT credential_payload FROM service_connections WHERE id = #{record.id.to_i}")
    assert_not_includes ciphertext, "old-refresh"
    assert_not_includes ciphertext, "old-access"
    assert_equal "old-refresh", record.reload.credential_payload_hash["refresh_token"]
    record.agent_service_accesses.create!(agent: agents(:research_assistant), enabled: true)
    manifest = Agents::ServiceManifest.new(agents(:research_assistant)).to_yaml
    [ "old-refresh", "old-access", "freeagent-secret", "refresh_token", "client_secret" ].each do |secret|
      assert_not_includes manifest, secret
    end
    assert_includes manifest, "access_token_endpoint"
  end

  test "refresh persists rotated token and expiry without changing authority revision" do
    record = connection
    stub_request(:post, TOKEN_URL)
      .with(basic_auth: %w[freeagent-client freeagent-secret],
        body: { "grant_type" => "refresh_token", "refresh_token" => "old-refresh" })
      .to_return(status: 200, body: tokens.to_json)
    assert_no_changes -> { record.reload.credential_revision } do
      assert_equal "synthetic-access", with_credentials { @adapter.current_access_token(record) }
    end
    assert_equal "synthetic-refresh", record.reload.credential_payload_hash["refresh_token"]
    assert Time.iso8601(record.credential_payload_hash["refresh_expires_at"]) > 23.hours.from_now
  end

  test "omitted refresh token and expiry retain the previous known values" do
    deadline = 1.day.from_now.utc.iso8601
    record = connection("refresh_expires_at" => deadline)
    stub_request(:post, TOKEN_URL).to_return(status: 200, body: { access_token: "new", expires_in: "3600" }.to_json)
    assert_equal "new", with_credentials { @adapter.current_access_token(record) }
    assert_equal "old-refresh", record.reload.credential_payload_hash["refresh_token"]
    assert_equal deadline, record.credential_payload_hash["refresh_expires_at"]
  end

  test "stale instance reload under lock preserves another caller's refreshed token" do
    record = connection
    stale = ServiceConnection.find(record.id)
    record.replace_credential_payload_without_reconciliation!(
      "access_token" => "already-refreshed", "refresh_token" => "already-rotated", "expires_at" => 30.minutes.from_now.utc.iso8601)
    assert_equal "already-refreshed", with_credentials { @adapter.current_access_token(stale) }
    assert_not_requested :post, TOKEN_URL
    assert_equal "already-rotated", stale.reload.credential_payload_hash["refresh_token"]
  end

  test "connected status is rechecked inside lock before returning even a fresh token" do
    record = connection("expires_at" => 30.minutes.from_now.utc.iso8601)
    stale = ServiceConnection.find(record.id)
    record.update!(status: "revoked")
    assert_raises(Services::FreeagentAdapter::Error) { with_credentials { @adapter.current_access_token(stale) } }
    assert_not_requested :post, TOKEN_URL
    assert_equal "revoked", stale.reload.status
  end

  test "terminal invalid grant commits reconnect status and clears credentials without leaking provider content" do
    record = connection
    stub_request(:post, TOKEN_URL).to_return(status: 400, body: { error: "invalid_grant", detail: "old-refresh" }.to_json)
    error = assert_raises(Services::FreeagentAdapter::DeadGrant) { with_credentials { @adapter.current_access_token(record) } }
    assert_not_includes error.message, "old-refresh"
    assert_equal "reauthorizing", record.reload.status
    assert_empty record.credential_payload_hash.to_h
  end

  test "expired refresh token is terminal locally even with a fresh access token" do
    record = connection("refresh_expires_at" => 1.minute.ago.utc.iso8601, "expires_at" => 30.minutes.from_now.utc.iso8601)
    assert_raises(Services::FreeagentAdapter::DeadGrant) { with_credentials { @adapter.current_access_token(record) } }
    assert_equal "reauthorizing", record.reload.status
    assert_empty record.credential_payload_hash.to_h
    assert_not_requested :post, TOKEN_URL
  end

  test "dead mark does not clear a grant reconnected after lock release" do
    record = connection
    stub_request(:post, TOKEN_URL).to_return(status: 400, body: { error: "invalid_grant" }.to_json)
    reconnect = -> {
      fresh = ServiceConnection.find(record.id)
      fresh.update!(status: "connected")
      fresh.replace_credential_payload_without_reconciliation!(
        "access_token" => "reconnected", "refresh_token" => "new-grant", "expires_at" => 30.minutes.from_now.utc.iso8601)
    }
    record.define_singleton_method(:with_lock) do |*args, &block|
      result = super(*args, &block)
      reconnect.call
      result
    end
    assert_raises(Services::FreeagentAdapter::DeadGrant) { with_credentials { @adapter.current_access_token(record) } }
    assert_equal "connected", record.reload.status
    assert_equal "new-grant", record.credential_payload_hash["refresh_token"]
  end

  test "network HTTP JSON shape and token failures do not kill the existing grant" do
    record = connection
    [
      { status: 503, body: "secret" }, { status: 302, headers: { "Location" => "https://evil.test/" } },
      { status: 400, body: '["invalid_grant","secret"]' },
      { status: 200, body: "<secret>" }, { status: 200, body: "[]" },
      { status: 200, body: { access_token: "secret", expires_in: 0 }.to_json },
      { status: 200, body: { access_token: "secret", refresh_token: nil, expires_in: 3600 }.to_json }
    ].each do |response|
      stub_request(:post, TOKEN_URL).to_return(response)
      error = assert_raises(Services::FreeagentAdapter::Error) { with_credentials { @adapter.current_access_token(record) } }
      assert_not_includes error.message, "secret"
      assert_equal "connected", record.reload.status
      assert_equal "old-refresh", record.credential_payload_hash["refresh_token"]
    end
    [ EOFError, Net::HTTPBadResponse, Net::OpenTimeout, OpenSSL::SSL::SSLError ].each do |failure|
      stub_request(:post, TOKEN_URL).to_raise(failure.new("secret"))
      error = assert_raises(Services::FreeagentAdapter::Error) { with_credentials { @adapter.current_access_token(record) } }
      assert_equal "FreeAgent could not be reached", error.message
      assert_equal "connected", record.reload.status
    end
  end

  test "malformed persisted refresh expiry is not treated as a terminal grant" do
    record = connection("refresh_expires_at" => "secret")
    error = assert_raises(Services::FreeagentAdapter::Error) { with_credentials { @adapter.current_access_token(record) } }
    assert_not_includes error.message, "secret"
    assert_equal "connected", record.reload.status
  end

  test "local revocation calls no invented provider endpoint" do
    record = connection
    assert_nil @adapter.revoke!(record)
    assert_nil @adapter.revoke(record)
    assert_not_requested :post, TOKEN_URL
  end

end
