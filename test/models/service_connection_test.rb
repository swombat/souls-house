require "test_helper"

class ServiceConnectionTest < ActiveSupport::TestCase

  test "refresh broker exposes only its broker endpoint" do
    user = users(:user_1)
    connection = accounts(:personal_account).service_connections.create!(
      connected_by_user: user,
      provider: "oura",
      external_subject_id: "oura-user-1",
      management_scope: "personal",
      credential_kind: "oauth2",
      credential_payload_hash: {
        "access_token" => "current-access-token",
        "refresh_token" => "private-refresh-token",
        "expires_at" => 2.days.from_now.utc.iso8601
      },
      credential_metadata: {
        "credential_strategy" => "refresh_broker",
        "granted_scopes" => OuraApi::SCOPES
      }
    )

    credentials = connection.runtime_credentials(agent: agents(:research_assistant))

    assert_not credentials.key?("access_token")
    assert_not credentials.key?("expires_at")
    assert_not credentials.key?("refresh_token")
    assert_includes credentials["access_token_endpoint"], "/api/v1/service_connections/svc_#{connection.id}/access_token"
  end

  test "credential rotation updates encrypted payload without changing authority revision" do
    connection = accounts(:personal_account).service_connections.create!(
      connected_by_user: users(:user_1),
      provider: "oura",
      external_subject_id: "oura-user-1",
      management_scope: "personal",
      credential_kind: "oauth2",
      credential_payload_hash: { "access_token" => "old", "refresh_token" => "refresh" },
      credential_metadata: { "credential_strategy" => "refresh_broker" }
    )

    assert_no_changes -> { connection.reload.credential_revision } do
      connection.replace_credential_payload_without_reconciliation!(
        "access_token" => "new",
        "refresh_token" => "rotated"
      )
    end

    assert_equal "new", connection.credential_payload_hash["access_token"]
    assert_equal "rotated", connection.credential_payload_hash["refresh_token"]
  end

  test "legacy Google scopes derive effective authority and request review" do
    connection = accounts(:personal_account).service_connections.create!(
      connected_by_user: users(:user_1),
      provider: "google_workspace",
      external_subject_id: "legacy-google-user",
      management_scope: "personal",
      credential_kind: "oauth2",
      credential_payload_hash: { "refresh_token" => "legacy-refresh" },
      credential_metadata: {
        "credential_strategy" => "refresh_broker",
        "granted_scopes" => [ "https://www.googleapis.com/auth/drive" ]
      }
    )

    assert_equal "write", connection.effective_authority["drive"]
    assert_equal "write", connection.effective_authority["docs"]
    assert_includes connection.authority_warnings, "Review access and reconnect to choose granular authority."
  end

  test "allows several fingerprinted credentials for one provider identity" do
    account = accounts(:personal_account)
    user = users(:user_1)

    first = account.service_connections.create!(
      connected_by_user: user,
      provider: "github",
      external_subject_id: "github-user-42",
      external_identity: "dad",
      management_scope: "personal",
      credential_kind: "token",
      credential_fingerprint: "fingerprint-one",
      credential_payload_hash: { "token" => "github_pat_one" }
    )
    second = account.service_connections.create!(
      connected_by_user: user,
      provider: "github",
      external_subject_id: "github-user-42",
      external_identity: "dad",
      management_scope: "personal",
      credential_kind: "token",
      credential_fingerprint: "fingerprint-two",
      credential_payload_hash: { "token" => "github_pat_two" }
    )

    assert_predicate first, :persisted?
    assert_predicate second, :persisted?
  end

  test "does not allow the same credential fingerprint twice" do
    account = accounts(:personal_account)
    attributes = {
      connected_by_user: users(:user_1),
      provider: "github",
      external_subject_id: "github-user-42",
      external_identity: "dad",
      management_scope: "personal",
      credential_kind: "token",
      credential_fingerprint: "same-fingerprint",
      credential_payload_hash: { "token" => "github_pat_one" }
    }
    account.service_connections.create!(attributes)
    duplicate = account.service_connections.new(attributes.merge(
      credential_payload_hash: { "token" => "github_pat_same" }
    ))

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:credential_fingerprint], "has already been taken"
  end

  test "GitHub runtime entry exposes the token and repository guidance without its fingerprint" do
    connection = accounts(:personal_account).service_connections.create!(
      connected_by_user: users(:user_1),
      provider: "github",
      external_subject_id: "github-user-42",
      external_identity: "dad",
      label: "dad/example-site",
      management_scope: "personal",
      credential_kind: "token",
      credential_fingerprint: "private-deduplication-fingerprint",
      credential_payload_hash: { "token" => "github_pat_secret" },
      credential_metadata: {
        "credential_strategy" => "static",
        "repository" => "dad/example-site",
        "authority_summary" => "Direct GitHub access intended for dad/example-site."
      }
    )

    entry = connection.runtime_entry(agent: agents(:research_assistant))

    assert_equal "github_pat_secret", entry.dig("credentials", "token")
    assert_equal "dad/example-site", entry.dig("metadata", "repository")
    assert_includes entry["notes"], "Use it with GitHub's API, gh CLI (GH_TOKEN), or Git over HTTPS."
    assert_not_includes entry.to_s, "private-deduplication-fingerprint"
  end

end
