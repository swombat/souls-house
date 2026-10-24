require "test_helper"

class GuestDirectoryFixtureTest < ActionDispatch::IntegrationTest

  test "fixture exercises actual synthetic guest join and callback-bypassing agent deletion" do
    account = Account.create!(name: "E2E Guest directory fixture", account_type: :team)
    account.add_user!(users(:user_1), role: "owner", skip_confirmation: true)
    %w[setup join leave join delete].each do |operation|
      post "/test/e2e/guest_directory_fixture", params: { account_id: account.id, operation: }, as: :json
      assert_response :success
    end
    assert_empty account.reload.guest_memberships
  end

  test "fixture refuses non-synthetic accounts" do
    post "/test/e2e/guest_directory_fixture",
      params: { account_id: accounts(:personal_account).id, operation: "setup" }, as: :json
    assert_response :not_found
  end

end
