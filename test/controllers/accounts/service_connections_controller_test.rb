require "test_helper"

class Accounts::ServiceConnectionsControllerTest < ActionDispatch::IntegrationTest

  setup do
    @user = users(:user_1)
    @account = accounts(:personal_account)
    sign_in @user
  end

  test "creates multiple GitHub repository credentials for the same GitHub user" do
    definition = Services::Definition.fetch("github")
    adapter = Object.new
    result_number = 0
    adapter.define_singleton_method(:connection_attributes) do |credentials:, user:|
      result_number += 1
      repository = credentials.fetch("repository")
      {
        external_subject_id: "github-user-42",
        external_identity: "dad",
        label: repository,
        credential_kind: "token",
        credential_fingerprint: "fingerprint-#{result_number}",
        credential_payload: { "token" => credentials.fetch("token") },
        credential_metadata: {
          "credential_strategy" => "static",
          "repository" => repository,
          "authority_summary" => "Direct GitHub access intended for #{repository}."
        }
      }
    end

    definition.stub :adapter, adapter do
      assert_difference "ServiceConnection.where(provider: 'github').count", 2 do
        post account_service_connections_path(@account), params: {
          provider: "github",
          management_scope: "personal",
          credentials: {
            token: "github_pat_first",
            repository: "dad/first-site"
          }
        }
        post account_service_connections_path(@account), params: {
          provider: "github",
          management_scope: "personal",
          credentials: {
            token: "github_pat_second",
            repository: "dad/second-site"
          }
        }
      end
    end

    connections = @account.service_connections.where(provider: "github").order(:id)
    assert_equal [ "github-user-42", "github-user-42" ], connections.pluck(:external_subject_id)
    assert_equal [ "dad/first-site", "dad/second-site" ], connections.pluck(:label)
    assert_equal "github_pat_first", connections.first.credential_payload_hash["token"]
    assert_equal "github_pat_second", connections.second.credential_payload_hash["token"]
    assert_redirected_to account_integrations_path(@account)
  end

  test "does not accept GitHub repository credentials as account managed" do
    post account_service_connections_path(@account), params: {
      provider: "github",
      management_scope: "account_managed",
      credentials: {
        token: "github_pat_secret",
        repository: "dad/site"
      }
    }

    assert_not ServiceConnection.exists?(provider: "github", account: @account)
    assert_redirected_to account_integrations_path(@account)
  end

  test "connects Tailscale with its own credential fields and hands them to a granted resident" do
    assert_difference "ServiceConnection.where(provider: 'tailscale').count", 1 do
      post account_service_connections_path(@account), params: {
        provider: "tailscale",
        management_scope: "personal",
        credentials: {
          auth_key: "tskey-auth-kTest-secret",
          hosts: "dell=daniel@dell",
          token: "not-a-tailscale-field"
        }
      }
    end
    assert_redirected_to account_integrations_path(@account)

    connection = @account.service_connections.find_by!(provider: "tailscale")
    assert_equal({ "auth_key" => "tskey-auth-kTest-secret" }, connection.credential_payload_hash)
    assert_equal [ { "alias" => "dell", "user" => "daniel", "machine" => "dell" } ], connection.credential_metadata["hosts"]

    agent = @account.agents.first || flunk("fixture account has no resident")
    agent.agent_service_accesses.find_or_create_by!(service_connection: connection).update!(enabled: true)
    entry = Agents::ServiceManifest.new(agent).to_h["services"].find { |s| s["provider"] == "tailscale" }
    assert_equal "tskey-auth-kTest-secret", entry.dig("credentials", "auth_key")
    assert_equal "dell", entry.dig("metadata", "hosts", 0, "alias")
  end

  test "rejects a Tailscale key that is not an auth key" do
    post account_service_connections_path(@account), params: {
      provider: "tailscale",
      management_scope: "personal",
      credentials: { auth_key: "tskey-api-secret" }
    }

    assert_not ServiceConnection.exists?(provider: "tailscale", account: @account)
    assert_match(/tskey-auth-/, flash[:alert])
  end

  test "does not store the same GitHub token twice" do
    definition = Services::Definition.fetch("github")
    adapter = Object.new
    adapter.define_singleton_method(:connection_attributes) do |credentials:, user:|
      {
        external_subject_id: "github-user-42",
        external_identity: "dad",
        label: credentials.fetch("repository"),
        credential_kind: "token",
        credential_fingerprint: "same-fingerprint",
        credential_payload: { "token" => credentials.fetch("token") },
        credential_metadata: {
          "credential_strategy" => "static",
          "repository" => credentials.fetch("repository")
        }
      }
    end

    definition.stub :adapter, adapter do
      post account_service_connections_path(@account), params: {
        provider: "github",
        management_scope: "personal",
        credentials: { token: "github_pat_secret", repository: "dad/site" }
      }

      assert_no_difference "ServiceConnection.count" do
        post account_service_connections_path(@account), params: {
          provider: "github",
          management_scope: "personal",
          credentials: { token: "github_pat_secret", repository: "dad/another-site" }
        }
      end
    end

    assert_redirected_to account_integrations_path(@account)
    assert_equal "That credential is already connected as dad/site", flash[:alert]
  end

end
