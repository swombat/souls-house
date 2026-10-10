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
    assert_equal %w[rails runtime chaos both], body["workflows"].map { |w| w["key"] }
    assert body.key?("alarm")
  end

  test "the summary carries the deploy alarm" do
    DeployAlarmState.create!(state: "stuck", since: 10.minutes.ago, behind_by: 2, reason: "No deploy has run since master moved ahead.",
      last_checked_at: 1.minute.ago)
    sign_in users(:site_admin_user)
    get admin_deploy_info_path, as: :json

    alarm = response.parsed_body["alarm"]
    assert_equal "stuck", alarm["state"]
    assert_equal 2, alarm["behind_by"]
    assert_equal "No deploy has run since master moved ahead.", alarm["reason"]
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
