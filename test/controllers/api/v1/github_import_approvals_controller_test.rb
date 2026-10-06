require "test_helper"
require_relative "../../../support/github_import_fixtures"

class Api::V1::GithubImportApprovalsControllerTest < ActionDispatch::IntegrationTest

  include GithubImportFixtures

  test "bootstrap is scoped to resident and refuses changed credentials" do
    request = import_request
    approve_fixture(request)
    owner, repo = request.repository.split("/")
    agent = request.create_agent!(account: request.account, name: "Bootstrap", runtime: "external",
      home_profile: "portable_v1", portable_home_id: request.portable_home_id,
      github_repo_url: "https://github.com/#{request.repository}", github_repo_owner: owner, github_repo_name: repo,
      container_image: request.approved_image)
    key = ApiKey.generate_for(users(:user_1), name: "synthetic bootstrap", agent: agent)
    headers = { "Authorization" => "Bearer #{key.raw_token}" }
    get api_v1_agent_github_import_approval_path, headers: headers
    assert_response :success
    assert_equal request.approved_credential_fingerprint, response.parsed_body["credential_fingerprint"]
    assert_equal "existing", response.parsed_body["sync_strategy"]
    assert_equal({}, response.parsed_body["sync_configuration"])
    assert_not_includes response.body, "github_pat_synthetic"
    request.service_connection.update!(credential_fingerprint: "rotated")
    get api_v1_agent_github_import_approval_path, headers: headers
    assert_response :conflict
    assert_equal "github_import_approval_required", response.parsed_body["code"]
    human = ApiKey.generate_for(users(:user_1), name: "synthetic human")
    get api_v1_agent_github_import_approval_path, headers: { "Authorization" => "Bearer #{human.raw_token}" }
    assert_response :forbidden
  end

end
