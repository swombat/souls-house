require "test_helper"

class Admin::DeployInfosControllerTest < ActionDispatch::IntegrationTest

  setup do
    @original_fetcher = DeployInfo.fetcher
    DeployInfo.fetcher = ->(_path) { nil }
  end

  teardown do
    DeployInfo.fetcher = @original_fetcher
  end

  test "site admin gets the summary" do
    sign_in users(:site_admin_user)
    get admin_deploy_info_path, as: :json

    assert_response :success
    body = response.parsed_body
    assert body.key?("deployed")
    assert body.key?("master")
    assert_nil body["master"]
  end

  test "non-admin gets nothing" do
    sign_in users(:user_1)
    get admin_deploy_info_path, as: :json

    assert_response :not_found
  end

  test "anonymous gets nothing" do
    get admin_deploy_info_path, as: :json

    assert_response :redirect
  end

end
