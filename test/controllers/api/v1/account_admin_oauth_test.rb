require "test_helper"
require "support/app_oauth_test_helper"

module Api
  module V1
    # Account administration with a native-app OAuth token. The token belongs
    # to a person, not an account: account-level actions act in the account
    # account_id names (else their default), and an action on one record acts
    # in that record's account, which may be any enabled account they belong to.
    class AccountAdminOauthTest < ActionDispatch::IntegrationTest

      include AppOauthTestHelper

      setup do
        @user = users(:existing_user)
        @personal = accounts(:existing_user_account)
        @team = accounts(:team_account)
        @another = accounts(:another_team)
        @user.update!(default_account_id: @personal.id)
        @client = create_app_client
        @tokens = sign_in_device
        @app_session = AppSession.where(user: @user).order(:id).last
        @notice = Notice.announce_to_account!(account: @team, body: "Team notice", expires_in_days: 7, created_by: users(:user_1))
      end

      test "account-level reads use the default account, or the one account_id names" do
        get api_v1_account_path, headers: bearer(@tokens)
        assert_response :success
        assert_equal @personal.to_param, response.parsed_body.dig("account", "id")

        get api_v1_account_path(account_id: @team.to_param), headers: bearer(@tokens)
        assert_response :success
        assert_equal @team.to_param, response.parsed_body.dig("account", "id")

        get api_v1_account_path(account_id: accounts(:regular_user_account).to_param), headers: bearer(@tokens)
        assert_response :not_found
      end

      test "a write on a record in a second, non-default account works without account_id, audited with the app session" do
        delete api_v1_account_notice_path(@notice), headers: bearer(@tokens)

        assert_response :success
        assert_not Notice.active.exists?(@notice.id)
        audit = AuditLog.find_by!(action: "expire_account_notice", auditable: @notice)
        assert_equal @team, audit.account
        assert_equal @user, audit.user
        assert_equal @app_session.id, audit.data["app_session_id"]
        assert_not audit.data.key?("api_key_id")
      end

      test "an account-level write in a named second account is audited there with the app session" do
        patch api_v1_account_path(account_id: @team.to_param), params: { name: "Renamed by the app" }, headers: bearer(@tokens), as: :json

        assert_response :success
        assert_equal "Renamed by the app", @team.reload.name
        audit = AuditLog.find_by!(action: "update_account_settings", account: @team)
        assert_equal @app_session.id, audit.data["app_session_id"]
      end

      test "naming a different account of theirs makes the record not found" do
        delete api_v1_account_notice_path(@notice, account_id: @another.to_param), headers: bearer(@tokens)

        assert_response :not_found
        assert Notice.active.exists?(@notice.id)
      end

      test "a disabled account is not found" do
        @team.disable!

        delete api_v1_account_notice_path(@notice), headers: bearer(@tokens)
        assert_response :not_found
        get api_v1_account_path(account_id: @team.to_param), headers: bearer(@tokens)
        assert_response :not_found
        assert Notice.active.exists?(@notice.id)
      end

      test "a departed member is not found" do
        memberships(:team_member).destroy!

        delete api_v1_account_notice_path(@notice), headers: bearer(@tokens)
        assert_response :not_found
        get api_v1_account_path(account_id: @team.to_param), headers: bearer(@tokens)
        assert_response :not_found
        assert Notice.active.exists?(@notice.id)
      end

      test "a disabled default account does not block records in another account" do
        @personal.disable!

        delete api_v1_account_notice_path(@notice), headers: bearer(@tokens)
        assert_response :success
        get api_v1_account_path(account_id: @personal.to_param), headers: bearer(@tokens)
        assert_response :not_found
      end

      test "a resident key is refused" do
        resident = ApiKey.generate_for(users(:user_1), name: "Resident", agent: agents(:research_assistant))

        delete api_v1_account_notice_path(@notice), headers: { "Authorization" => "Bearer #{resident.raw_token}" }
        assert_response :forbidden
        get api_v1_account_path, headers: { "Authorization" => "Bearer #{resident.raw_token}" }
        assert_response :forbidden
        assert Notice.active.exists?(@notice.id)
      end

    end
  end
end
