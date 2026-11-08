require "test_helper"

class Services::GoogleWorkspaceAdapterTest < ActiveSupport::TestCase

  setup do
    @credentials = Object.new
    @credentials.define_singleton_method(:dig) do |*keys|
      {
        [ :google_workspace, :client_id ] => "google-client-id",
        [ :google_workspace, :client_secret ] => "google-client-secret"
      }[keys]
    end
    @adapter = Services::Definition.fetch("google_workspace").adapter
  end

  test "uses configured OAuth credentials" do
    Rails.application.stub(:credentials, @credentials) do
      assert_equal "google-client-id", @adapter.send(:client_id)
      assert_equal "google-client-secret", @adapter.send(:client_secret)
    end
  end

  test "defines exact read-only and full Workspace authority profiles" do
    definition = Services::Definition.fetch("google_workspace")

    assert_equal [
      "openid",
      "https://www.googleapis.com/auth/userinfo.email",
      "https://www.googleapis.com/auth/gmail.readonly",
      "https://www.googleapis.com/auth/calendar.readonly",
      "https://www.googleapis.com/auth/drive.readonly",
      "https://www.googleapis.com/auth/documents.readonly",
      "https://www.googleapis.com/auth/spreadsheets.readonly",
      "https://www.googleapis.com/auth/presentations.readonly",
      "https://www.googleapis.com/auth/meetings.space.readonly"
    ], definition.scopes_for("read_only")

    assert_equal [
      "openid",
      "https://www.googleapis.com/auth/userinfo.email",
      "https://mail.google.com/",
      "https://www.googleapis.com/auth/calendar",
      "https://www.googleapis.com/auth/drive",
      "https://www.googleapis.com/auth/documents",
      "https://www.googleapis.com/auth/spreadsheets",
      "https://www.googleapis.com/auth/presentations",
      "https://www.googleapis.com/auth/meetings.space.settings"
    ], definition.scopes_for("full_access")
  end

  test "compiles an exact granular authority selection without Gmail or Meet" do
    definition = Services::Definition.fetch("google_workspace")
    selection = {
      drive: "write",
      docs: "write",
      sheets: "write",
      slides: "write",
      calendar: "read",
      gmail: "none",
      meet: "none"
    }

    scopes = definition.scopes_for_authority(selection)

    assert_includes scopes, "https://www.googleapis.com/auth/drive"
    assert_includes scopes, "https://www.googleapis.com/auth/calendar.readonly"
    assert_not scopes.any? { |scope| scope.include?("gmail") || scope == "https://mail.google.com/" }
    assert_not scopes.any? { |scope| scope.include?("meetings.space") }
  end

  test "Drive authority floors effective Docs Sheets and Slides authority" do
    effective = @adapter.effective_authority(
      [ "https://www.googleapis.com/auth/drive" ],
      requested_selection: {
        drive: "write", docs: "none", sheets: "none", slides: "none",
        calendar: "none", gmail: "none", meet: "none"
      }
    )

    assert_equal "write", effective.dig("selection", "drive")
    assert_equal "write", effective.dig("selection", "docs")
    assert_equal "write", effective.dig("selection", "sheets")
    assert_equal "write", effective.dig("selection", "slides")
  end

  test "does not treat requested scopes as provider-confirmed when scope is omitted" do
    attempt = ServiceAuthorizationAttempt.new(
      authority_selection: {
        drive: "none", docs: "none", sheets: "write", slides: "none",
        calendar: "read", gmail: "none", meet: "none"
      },
      requested_scopes: [
        "openid",
        "https://www.googleapis.com/auth/userinfo.email",
        "https://www.googleapis.com/auth/spreadsheets",
        "https://www.googleapis.com/auth/calendar.readonly"
      ]
    )

    metadata = @adapter.send(:credential_metadata, {}, attempt)

    assert_nil metadata["granted_scopes"]
    assert_includes metadata["authority_warnings"], "Google did not confirm the granted scopes."
    assert_equal "write", metadata.dig("effective_authority", "sheets")
  end

  test "refreshes through the broker without replacing the refresh token" do
    connection = accounts(:personal_account).service_connections.create!(
      connected_by_user: users(:user_1),
      provider: "google_workspace",
      external_subject_id: "google-user-1",
      management_scope: "personal",
      credential_kind: "oauth2",
      credential_payload_hash: {
        "access_token" => "expired-access",
        "refresh_token" => "private-refresh",
        "expires_at" => 1.minute.ago.utc.iso8601
      },
      credential_metadata: { "credential_strategy" => "refresh_broker" }
    )
    refreshed = {
      "access_token" => "fresh-access",
      "expires_in" => 3600,
      "scope" => Services::Catalog::GOOGLE_WORKSPACE_READ.join(" ")
    }

    Rails.application.stub(:credentials, @credentials) do
      @adapter.stub(:token_request, refreshed) do
        assert_equal "fresh-access", @adapter.current_access_token(connection)
      end
    end

    assert_equal "private-refresh", connection.reload.credential_payload_hash["refresh_token"]
    assert_in_delta Time.current, connection.last_refreshed_at, 2
  end

  test "invalid refresh grant persists one audited reauthorization without changing resident grants" do
    connection = expired_connection
    access = connection.agent_service_accesses.create!(agent: agents(:research_assistant), enabled: true)
    grants = connection.agent_service_accesses.order(:id).pluck(:id, :enabled)
    metadata = connection.credential_metadata
    last_good = 3.days.ago.change(usec: 0)
    connection.update_columns(last_refreshed_at: last_good)
    response = oauth_response(Net::HTTPBadRequest, '{"error":"invalid_grant","error_description":"private-provider-body"}')

    assert_difference -> { AuditLog.where(action: "service_connection_reauthorization_required").count }, 1 do
      with_token_response(response) do
        assert_raises(Services::GoogleWorkspaceAdapter::ReauthorizationRequired) { @adapter.current_access_token(connection) }
      end
      Net::HTTP.stub(:post_form, ->(*) { flunk "must not retry or revoke" }) do
        assert_raises(Services::GoogleWorkspaceAdapter::ReauthorizationRequired) { @adapter.current_access_token(connection) }
      end
    end

    assert_equal "reauthorizing", connection.reload.status
    assert_nil connection.credential_payload
    assert_equal last_good, connection.last_refreshed_at
    assert_equal metadata, connection.credential_metadata
    assert_equal grants, connection.agent_service_accesses.order(:id).pluck(:id, :enabled)
    assert access.reload.enabled?
    audit = AuditLog.find_by!(auditable: connection, action: "service_connection_reauthorization_required")
    assert_nil audit.user_id
    assert_equal connection.account_id, audit.account_id
    assert_equal({ "provider" => "google_workspace", "reason" => "invalid_grant",
                   "status" => [ "connected", "reauthorizing" ] }, audit.data)
  end

  test "only a refresh endpoint invalid_grant marks reauthorization" do
    [
      [ Net::HTTPTooManyRequests, '{"error":"invalid_grant"}' ],
      [ Net::HTTPServiceUnavailable, '{"error":"invalid_grant"}' ],
      [ Net::HTTPBadRequest, '{"error":"invalid_client"}' ],
      [ Net::HTTPBadRequest, "not-json" ],
      [ Net::HTTPBadRequest, '["invalid_grant"]' ],
      [ Net::HTTPBadRequest, "null" ]
    ].each do |klass, body|
      connection = expired_connection
      assert_no_difference -> { AuditLog.count } do
        with_token_response(oauth_response(klass, body)) do
          error = assert_raises(Services::GoogleWorkspaceAdapter::Error) { @adapter.current_access_token(connection) }
          assert_not_kind_of Services::GoogleWorkspaceAdapter::ReauthorizationRequired, error
        end
      end
      assert_equal "connected", connection.reload.status
      assert_equal "private-refresh", connection.credential_payload_hash["refresh_token"]
      assert_nil connection.last_refreshed_at
    end
  end

  test "network failures leave the connection connected" do
    connection = expired_connection
    Rails.application.stub(:credentials, @credentials) do
      Net::HTTP.stub(:post_form, ->(*) { raise Net::OpenTimeout }) do
        assert_raises(Net::OpenTimeout) { @adapter.current_access_token(connection) }
      end
    end
    assert_equal "connected", connection.reload.status
  end

  test "authorization code invalid_grant is not a rejected refresh grant" do
    with_token_response(oauth_response(Net::HTTPBadRequest, '{"error":"invalid_grant"}')) do
      error = assert_raises(Services::GoogleWorkspaceAdapter::Error) do
        @adapter.exchange_code(code: "old-code", attempt: ServiceAuthorizationAttempt.new(pkce_verifier: "verifier"), redirect_uri: "https://example.test/callback")
      end
      assert_not_kind_of Services::GoogleWorkspaceAdapter::ReauthorizationRequired, error
    end
  end

  test "checks current status under lock even when a cached token is fresh" do
    connection = expired_connection
    stale = ServiceConnection.find(connection.id)
    connection.update!(status: "reauthorizing", credential_payload_hash: { "access_token" => "fresh-but-unusable", "expires_at" => 1.hour.from_now.iso8601 })
    Net::HTTP.stub(:post_form, ->(*) { flunk "must not refresh a stale caller" }) do
      assert_raises(Services::GoogleWorkspaceAdapter::ReauthorizationRequired) { @adapter.current_access_token(stale) }
    end
  end

  test "a rejected refresh cannot clear a grant reconnected after the lock commits" do
    connection = expired_connection
    reconnect = -> {
      fresh = ServiceConnection.find(connection.id)
      fresh.update!(status: "connected")
      fresh.replace_credential_payload_without_reconciliation!(
        "access_token" => "new-access", "refresh_token" => "new-grant", "expires_at" => 1.hour.from_now.iso8601)
    }
    connection.define_singleton_method(:with_lock) do |*args, &block|
      result = super(*args, &block)
      reconnect.call
      result
    end
    with_token_response(oauth_response(Net::HTTPBadRequest, '{"error":"invalid_grant"}')) do
      assert_raises(Services::GoogleWorkspaceAdapter::ReauthorizationRequired) { @adapter.current_access_token(connection) }
    end
    assert_equal "connected", connection.reload.status
    assert_equal "new-grant", connection.credential_payload_hash["refresh_token"]
  end

  private

  def expired_connection
    accounts(:personal_account).service_connections.create!(
      connected_by_user: users(:user_1), provider: "google_workspace",
      external_subject_id: SecureRandom.uuid, management_scope: "personal", credential_kind: "oauth2",
      credential_payload_hash: { "access_token" => "expired", "refresh_token" => "private-refresh", "expires_at" => 1.minute.ago.iso8601 },
      credential_metadata: { "credential_strategy" => "refresh_broker" }
    )
  end

  def oauth_response(klass, body)
    response = klass.new("1.1", Net::HTTPResponse::CODE_TO_OBJ.key(klass), "test response")
    response.define_singleton_method(:body) { body }
    response
  end

  def with_token_response(response)
    Rails.application.stub(:credentials, @credentials) do
      Net::HTTP.stub(:post_form, ->(uri, params) {
        assert_equal Services::GoogleWorkspaceAdapter::TOKEN_URL, uri.to_s
        assert_equal "google-client-secret", params[:client_secret]
        response
      }) { yield }
    end
  end

end
