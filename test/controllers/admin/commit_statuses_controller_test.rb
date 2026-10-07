require "test_helper"

class Admin::CommitStatusesControllerTest < ActionDispatch::IntegrationTest

  setup do
    @original_deploy_fetcher = DeployInfo.fetcher
    @original_fetcher = CommitStatus.fetcher
    DeployInfo.fetcher = ->(_path) { nil }
    CommitStatus.fetcher = ->(_path) { [ 404, nil ] }
  end

  teardown do
    DeployInfo.fetcher = @original_deploy_fetcher
    CommitStatus.fetcher = @original_fetcher
  end

  test "site admin gets statuses keyed by the requested sha" do
    sign_in users(:site_admin_user)
    get admin_commit_statuses_path(shas: "51625a7,notasha"), as: :json

    assert_response :success
    assert_equal({ "51625a7" => nil }, response.parsed_body["statuses"])
    assert response.parsed_body.key?("revision")
  end

  test "non-admin gets nothing" do
    sign_in users(:user_1)
    get admin_commit_statuses_path(shas: "51625a7"), as: :json

    assert_response :not_found
  end

  test "anonymous gets nothing" do
    get admin_commit_statuses_path(shas: "51625a7"), as: :json

    assert_response :redirect
  end

end
