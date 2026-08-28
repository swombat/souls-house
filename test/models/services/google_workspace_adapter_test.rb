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
  end

end
