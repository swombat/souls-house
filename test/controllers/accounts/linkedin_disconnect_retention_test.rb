require "test_helper"
require "webmock/minitest"
require "support/linkedin_test_helpers"

# #93: retaining the ledger must not retain authority to publish.
class Accounts::LinkedinDisconnectRetentionTest < ActionDispatch::IntegrationTest

  include LinkedinTestHelpers

  setup do
    WebMock.disable_net_connect!
    @user = users(:user_1)
    @agent = agents(:research_assistant)
    @account = @agent.account
    @connection = linkedin_connection(account: @account, user: @user)
    @agent.agent_service_accesses.create!(service_connection: @connection, enabled: true)
    @revoke = stub_request(:post, Services::LinkedinAdapter::REVOKE_URL)
      .with(body: { token: "li-access", client_id: "li-client", client_secret: "li-secret" })
      .to_return(status: 200, body: "{}")
    sign_in @user
  end

  LinkedinPost::STATUSES.each do |status|
    test "ordinary disconnect preserves #{status} publication history and provenance" do
      publication = publication_with(status)
      original = publication.attributes

      disconnect_through_owner_route

      assert LinkedinPost.exists?(publication.id), "ordinary disconnect destroyed the #{status} publication"
      assert_equal original, publication.reload.attributes
      assert_equal @connection.id, publication.service_connection_id
      assert_equal @agent.id, publication.agent_id
      assert_equal "revoked", @connection.reload.status
      assert_nil @connection.credential_payload
      assert_equal({}, @connection.credential_payload_hash)
    end
  end

  test "disconnect itself revokes and erases credentials without changing publication provenance" do
    publication = publication_with("resolved_posted")
    original = publication.attributes
    revision = @connection.credential_revision

    with_linkedin_credentials { @connection.disconnect! }

    assert_requested @revoke, times: 1
    assert_equal "revoked", @connection.reload.status
    assert_nil @connection.credential_payload
    assert_equal({}, @connection.credential_payload_hash)
    assert_equal revision + 1, @connection.credential_revision
    assert_equal original, publication.reload.attributes
    assert_publishing_denied(code: "reconnect_needed", http_status: :conflict)
  end

  test "ordinary disconnect denies further publishing without contacting LinkedIn" do
    publication_with("posted")

    disconnect_through_owner_route

    assert_publishing_denied(code: "reconnect_needed", http_status: :conflict)
  end

  test "revoked history remains readable and locally resolvable only by its resident" do
    publication = publication_with("outcome_unknown")
    disconnect_through_owner_route
    key = ApiKey.generate_for(@user, name: "History audit", agent: @agent)
    headers = { "Authorization" => "Bearer #{key.raw_token}" }

    get "/api/v1/linkedin_posts/#{publication.to_param}", headers: headers
    assert_response :ok
    assert_equal "outcome_unknown", response.parsed_body["status"]
    patch "/api/v1/linkedin_posts/#{publication.to_param}",
      params: { resolution: "posted", post_urn: "urn:li:share:7100000000000000093" },
      headers: headers, as: :json
    assert_response :ok
    assert_equal "resolved_posted", publication.reload.status
    assert_equal @agent, publication.resolved_by_agent
    assert_equal "revoked", @connection.reload.status
    assert_nil @connection.credential_payload

    other_key = ApiKey.generate_for(@user, name: "Other resident", agent: agents(:code_reviewer))
    other_headers = { "Authorization" => "Bearer #{other_key.raw_token}" }
    get "/api/v1/linkedin_posts/#{publication.to_param}", headers: other_headers
    assert_response :not_found
    patch "/api/v1/linkedin_posts/#{publication.to_param}",
      params: { resolution: "not_posted" }, headers: other_headers, as: :json
    assert_response :not_found
    assert_equal "resolved_posted", publication.reload.status
    assert_not_requested :post, "https://api.linkedin.com/rest/posts"
  end

  test "reconnect retains the ledger but resets manual and default sharing before credentials become usable" do
    publication = publication_with("outcome_unknown")
    pending = publication_with("pending")
    original = publication.attributes
    @connection.update!(enabled_for_new_agents: true, freely_provisionable: true)
    access = @connection.agent_service_accesses.find_by!(agent: @agent)
    access.update!(follows_default: false)
    default_access = @connection.agent_service_accesses.create!(agent: agents(:code_reviewer), enabled: true, follows_default: true)
    disconnect_through_owner_route

    reconnect_through_oauth

    assert_equal "connected", @connection.reload.status
    assert_equal "li-reconnected", @connection.credential_payload_hash["access_token"]
    assert_not @connection.enabled_for_new_agents?
    assert_not @connection.freely_provisionable?
    assert_not access.reload.enabled?
    assert_not access.follows_default?
    assert_not default_access.reload.enabled?
    assert_not default_access.follows_default?
    assert_equal original, publication.reload.attributes
    assert_publishing_denied
    LinkedinPoster.deliver!(pending)
    assert_equal "failed", pending.reload.status
    assert_equal "access_removed", pending.failure_reason

    # Once the owner explicitly grants access again, a spent key still cannot
    # create another post. In particular an uncertain response is never retried.
    access.update!(enabled: true)
    replay = LinkedinPoster.new(agent: @agent.reload).post!(
      text: publication.text, idempotency_key: publication.idempotency_key,
      connection_id: @connection.public_id
    )
    assert replay.replayed
    assert_equal publication.id, replay.post.id
    assert_equal "outcome_unknown", replay.post.status
    assert_not_requested :post, "https://api.linkedin.com/rest/posts"
  end

  test "refreshing a still-connected LinkedIn identity does not reset its existing sharing" do
    access = @connection.agent_service_accesses.find_by!(agent: @agent)
    @connection.update!(enabled_for_new_agents: true, freely_provisionable: true)

    reconnect_through_oauth

    assert access.reload.enabled?
    assert @connection.reload.enabled_for_new_agents?
    assert @connection.freely_provisionable?
  end

  test "a failed reconnect rolls back grant and default resets with the credential write" do
    publication_with("posted")
    access = @connection.agent_service_accesses.find_by!(agent: @agent)
    @connection.update!(enabled_for_new_agents: true, freely_provisionable: true)
    disconnect_through_owner_route

    # A too-long new label fails the connection validation after the access
    # updates, proving they share the surrounding transaction.
    reconnect_through_oauth(name: "x" * 101, succeeds: false)
    assert_response :unprocessable_entity

    assert access.reload.enabled?
    assert @connection.reload.enabled_for_new_agents?
    assert @connection.freely_provisionable?
    assert_equal "revoked", @connection.status
    assert_nil @connection.credential_payload
  end

  test "reviving another provider does not reset its sharing" do
    connection = @account.service_connections.create!(
      provider: "github", external_subject_id: "github-user", connected_by_user: @user,
      management_scope: "personal", status: "revoked", credential_kind: "oauth2",
      enabled_for_new_agents: true, freely_provisionable: true
    )
    access = connection.agent_service_accesses.find_by!(agent: @agent)
    attempt, state = ServiceAuthorizationAttempt.begin!(
      account: @account, user: @user, provider: "github", management_scope: "personal",
      return_path: account_integrations_path(@account)
    )
    adapter = Object.new
    adapter.define_singleton_method(:exchange_code) do |**|
      { external_subject_id: "github-user", credential_kind: "oauth2",
        credential_payload: { "access_token" => "synthetic-github-token" }, credential_metadata: {} }
    end
    attempt.definition.stub(:adapter, adapter) do
      get service_authorization_callback_path, params: { state: state, code: "synthetic-code" }
    end

    assert_response :redirect
    assert_equal "connected", connection.reload.status
    assert access.reload.enabled?
    assert connection.enabled_for_new_agents?
    assert connection.freely_provisionable?
  end

  private

  def publication_with(status)
    @connection.linkedin_posts.create!(
      agent: @agent, text: "Synthetic retained publication",
      status: status, idempotency_key: "audit-93-#{status}",
      request_digest: Digest::SHA256.hexdigest({ text: "Synthetic retained publication", connection: @connection.public_id, media_kind: nil, media_digest: nil }.to_json),
      post_urn: ("urn:li:share:7100000000000000093" if status.in?(%w[posted resolved_posted])),
      resolved_by_agent: (@agent if status == "resolved_posted"),
      resolved_at: (Time.current if status == "resolved_posted")
    )
  end

  def disconnect_through_owner_route
    with_linkedin_credentials do
      delete account_service_connection_path(@account, @connection.public_id)
    end
    assert_redirected_to account_integrations_path(@account)
    assert_requested @revoke, times: 1
  end

  def reconnect_through_oauth(name: "Synthetic member", succeeds: true)
    _attempt, state = ServiceAuthorizationAttempt.begin!(
      account: @account, user: @user, provider: "linkedin", management_scope: "personal",
      return_path: account_integrations_path(@account)
    )
    exchange = stub_request(:post, Services::LinkedinAdapter::TOKEN_URL)
      .to_return(status: 200, body: { access_token: "li-reconnected", expires_in: 3600, scope: "openid profile w_member_social" }.to_json)
    identity = stub_request(:get, Services::LinkedinAdapter::USERINFO_URL)
      .with(headers: { "Authorization" => "Bearer li-reconnected" })
      .to_return(status: 200, body: { sub: "abc123", name: name }.to_json)
    with_linkedin_credentials do
      assert_no_difference "ServiceConnection.count" do
        get service_authorization_callback_path, params: { state: state, code: "synthetic-code" }
      end
    end
    return unless succeeds

    assert_response :redirect
    assert_match(/connected/, flash[:notice])
    assert_requested exchange, times: 1
    assert_requested identity, times: 1
    WebMock.reset_executed_requests!
  end

  def assert_publishing_denied(code: "not_connected", http_status: :forbidden)
    assert_no_difference "LinkedinPost.count" do
      error = assert_raises(LinkedinPoster::Refused) do
        LinkedinPoster.new(agent: @agent.reload).post!(
          text: "Must never publish", idempotency_key: "audit-93-denied",
          connection_id: @connection.public_id
        )
      end
      assert_equal code, error.code
      assert_equal http_status, error.http_status
    end
    assert_not_requested :post, "https://api.linkedin.com/rest/posts"
    assert_not_requested :post, Services::LinkedinAdapter::TOKEN_URL
  end

end
