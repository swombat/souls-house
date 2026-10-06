require "test_helper"
require_relative "../support/github_import_fixtures"

class GithubResidentImportsControllerTest < ActionDispatch::IntegrationTest

  include GithubImportFixtures

  setup do
    Setting.instance.update!(allow_agents: true)
    @account = accounts(:personal_account)
    login_as(users(:user_1))
  end

  test "submission previews data and queues nothing until site approval" do
    connection = import_connection
    Agents::GithubImportSource.stub(:new, source_stub) do
      assert_difference("GithubResidentImport.count") do
        assert_no_difference("Agent.count") do
          assert_no_enqueued_jobs do
            post account_github_resident_imports_path(@account), params: {
              github_resident_import: { name: "From GitHub", model_id: Chat::MODELS.first[:model_id],
                service_connection_id: connection.public_id, branch: "main", container_image: "evil", home_profile: "mira_v1" }
            }
          end
        end
      end
    end
    request = GithubResidentImport.last
    assert_redirected_to account_github_resident_import_path(@account, request)
    assert_equal "pending_review", request.status
    post approve_account_github_resident_import_path(@account, request), params: { confirmed: "true" }
    assert_response :forbidden
    login_as(users(:site_admin_user))
    Agents::GithubImportSource.stub(:new, source_stub(request)) do
      assert_enqueued_with(job: GithubResidentImportJob, args: [ request.id ]) do
        post approve_account_github_resident_import_path(@account, request),
          params: { confirmed: "true", review_revision: request.review_revision }
      end
    end
    assert_equal "approved", request.reload.status
  end

  test "show exposes safe authority and opaque fingerprints only" do
    request = import_request
    get account_github_resident_import_path(@account, request)
    assert_response :success
    props = inertia_shared_props
    assert_equal "fine_grained", props.dig("github_import", "token_metadata", "token_kind")
    assert_nil props.dig("github_import", "token_metadata", "oauth_scopes")
    assert_nil props["approve_url"]
    assert_equal 12, props.dig("github_import", "credential_fingerprint").length
    assert_not_includes response.body, "github_pat_synthetic"
    assert_not_includes response.body, request.credential_fingerprint
  end

  test "members unconfirmed users and cross-account credentials cannot submit" do
    login_as(users(:existing_user))
    get new_account_github_resident_import_path(accounts(:team_account))
    assert_response :forbidden
    login_as(users(:user_1))
    connection = import_connection(account: accounts(:regular_user_account))
    post account_github_resident_imports_path(@account), params: {
      github_resident_import: { name: "Wrong", model_id: Chat::MODELS.first[:model_id],
        service_connection_id: connection.public_id, branch: "main" }
    }
    assert_response :not_found
  end

  test "old fine-grained connection format is classified safely and rotation enables refresh not approval" do
    request = import_request
    request.service_connection.update!(credential_metadata: request.service_connection.credential_metadata.except("token_kind"))
    get new_account_github_resident_import_path(@account)
    assert_equal "fine_grained", inertia_shared_props.dig("connections", 0, "token_metadata", "token_kind")
    assert_nil inertia_shared_props.dig("connections", 0, "token_metadata", "oauth_scopes")
    login_as(users(:site_admin_user))
    request.service_connection.credential_payload_hash = { "token" => "github_pat_changed" }
    request.service_connection.save!
    @inertia_props = nil
    get account_github_resident_import_path(@account, request)
    assert inertia_shared_props.dig("github_import", "credential_changed")
    Agents::GithubImportSource.stub(:new, source_stub(request)) do
      assert_no_enqueued_jobs do
        post approve_account_github_resident_import_path(@account, request),
          params: { confirmed: "true", review_revision: request.review_revision }
      end
    end
    assert_equal "pending_review", request.reload.status
    assert_equal "Approval failed. Review the current request and credential.", flash[:alert]
  end

  private

  def login_as(user)
    delete logout_path
    post login_path, params: { email_address: user.email_address, password: "password123" }
  end

end
