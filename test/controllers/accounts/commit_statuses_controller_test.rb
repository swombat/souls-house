require "test_helper"

class Accounts::CommitStatusesControllerTest < ActionDispatch::IntegrationTest

  setup do
    @original_deploy_fetcher = DeployInfo.fetcher
    @original_fetcher = CommitStatus.fetcher
    DeployInfo.fetcher = ->(_path) { nil }
    CommitStatus.fetcher = ->(_path, token: nil) { [ 404, nil ] }
  end

  teardown do
    DeployInfo.fetcher = @original_deploy_fetcher
    CommitStatus.fetcher = @original_fetcher
  end

  test "a member gets statuses keyed by the requested reference" do
    sign_in users(:site_admin_user)
    get account_commit_statuses_path(accounts(:personal_account), refs: "51625a7,acme/web@783ab2e,notasha"), as: :json

    assert_response :success
    assert_equal({ "51625a7" => nil, "acme/web@783ab2e" => nil }, response.parsed_body["statuses"])
    assert response.parsed_body.key?("revision")
  end

  test "someone outside the account gets nothing" do
    sign_in users(:existing_user)
    get account_commit_statuses_path(accounts(:personal_account), refs: "51625a7"), as: :json

    assert_response :not_found
  end

  test "anonymous gets nothing" do
    get account_commit_statuses_path(accounts(:personal_account), refs: "51625a7"), as: :json

    assert_response :redirect
  end

end
