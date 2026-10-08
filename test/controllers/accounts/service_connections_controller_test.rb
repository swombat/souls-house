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

  test "connects Tailscale with nothing pasted, ignores stray fields, and grants a resident a sign-in entry" do
    assert_difference "ServiceConnection.where(provider: 'tailscale').count", 1 do
      post account_service_connections_path(@account), params: {
        provider: "tailscale",
        management_scope: "personal",
        credentials: { auth_key: "tskey-auth-kTest-secret", token: "not-a-tailscale-field" }
      }
    end
    assert_redirected_to account_integrations_path(@account)

    connection = @account.service_connections.find_by!(provider: "tailscale")
    assert_equal({}, connection.credential_payload_hash, "the form has no fields, so nothing pasted is stored")
    assert_equal "sign_in", connection.credential_metadata["join"]

    agent = @account.agents.first || flunk("fixture account has no resident")
    agent.agent_service_accesses.find_or_create_by!(service_connection: connection).update!(enabled: true)
    entry = Agents::ServiceManifest.new(agent).to_h["services"].find { |s| s["provider"] == "tailscale" }
    assert_equal({}, entry["credentials"])
  end

  test "connects Tailscale without any credentials param at all, once per account" do
    post account_service_connections_path(@account), params: { provider: "tailscale", management_scope: "personal" }
    assert_redirected_to account_integrations_path(@account)
    assert_equal 1, @account.service_connections.where(provider: "tailscale").count

    assert_no_difference "ServiceConnection.count" do
      post account_service_connections_path(@account), params: { provider: "tailscale", management_scope: "personal" }
    end
    assert_match(/already connected/, flash[:alert])
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


  # Mira #231: `.present?` let a JSON false through for a manager who is not
  # the personal connection's owner.
  test "only the personal owner changes delegation, even to false" do
    team = accounts(:team_account)
    connection = team.service_connections.create!(
      connected_by_user: users(:existing_user), provider: "github", external_subject_id: "github-user-web-delegation",
      external_identity: "member", label: "member/repository", management_scope: "personal", credential_kind: "token",
      credential_fingerprint: "web-delegation-fingerprint", credential_payload_hash: { "token" => "github_pat_secret" },
      credential_metadata: { "credential_strategy" => "static", "repository" => "member/repository" },
      freely_provisionable: true
    )

    patch account_service_connection_path(team, connection.public_id),
      params: { service_connection: { freely_provisionable: false, label: "Relabelled" } }, as: :json
    connection.reload
    assert connection.freely_provisionable?
    assert_equal "Relabelled", connection.label

    patch account_service_connection_path(team, connection.public_id),
      params: { service_connection: { freely_provisionable: "0" } }
    assert connection.reload.freely_provisionable?
  end

end
