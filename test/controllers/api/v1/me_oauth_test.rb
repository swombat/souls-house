require "test_helper"
require "support/app_oauth_test_helper"

# /api/v1/me, /me/avatar and /accounts with a native-app OAuth token, and the
# account rules for these person-level endpoints: identity and discovery never
# need a selected account; an account a request names (or an API key's
# account) must be enabled with a current confirmed membership, else 404.
module Api
  module V1
    class MeOauthTest < ActionDispatch::IntegrationTest

      include AppOauthTestHelper

      setup do
        @user = users(:existing_user)
        @personal = accounts(:existing_user_account)
        @team = accounts(:team_account)
        @another = accounts(:another_team)
        @client = create_app_client
        @tokens = sign_in_device
        @app_session = row_for(@tokens).app_session
      end

      test "an OAuth token reads /me and lists every enabled confirmed membership" do
        get api_v1_accounts_path, headers: bearer(@tokens)
        assert_response :success
        listed = response.parsed_body.fetch("accounts").to_h { |a| [ a["id"], a["role"] ] }
        assert_equal({ @personal.to_param => "owner", @team.to_param => "member", @another.to_param => "member" }, listed)

        get api_v1_me_path, headers: bearer(@tokens)
        assert_response :success
        me = response.parsed_body.fetch("user")
        assert_equal @user.to_param, me["id"]
        assert_equal listed.keys.sort, me["accounts"].map { |a| a["id"] }.sort
      end

      # (a) The person's second, non-default account, without account_id.
      test "PATCH /me sets a non-default account as default without account_id and audits the app session" do
        @user.update!(default_account_key: @personal.to_param)

        assert_difference -> { AuditLog.where(user: @user, action: "update_profile").count }, 1 do
          patch api_v1_me_path, headers: bearer(@tokens), as: :json, params: { default_account_id: @team.to_param }
        end

        assert_response :success
        assert_equal @team.id, @user.reload.default_account_id
        assert_equal({ "id" => @team.to_param, "name" => @team.name }, response.parsed_body.dig("user", "default_account"))
        log = AuditLog.where(user: @user).order(:id).last
        assert_equal @app_session.id, log.data["app_session_id"]
        assert_nil log.data["api_key_id"]
        assert_equal @personal, log.account, "filed under the account in use when none is named"
      end

      test "avatar upload and removal with an OAuth token audit the app session" do
        put api_v1_me_avatar_path, headers: bearer(@tokens), params: { avatar: fixture_file_upload("test_avatar.png", "image/png") }
        assert_response :success
        assert @user.reload.avatar.attached?
        assert_equal @app_session.id, AuditLog.where(user: @user, action: "set_avatar").last.data["app_session_id"]

        delete api_v1_me_avatar_path, headers: bearer(@tokens)
        assert_response :success
        assert_equal @app_session.id, AuditLog.where(user: @user, action: "remove_avatar").last.data["app_session_id"]
      end

      # (b) account_id narrows which account the action is filed under; an
      # account that is not theirs is 404 and nothing changes.
      test "account_id naming one of the person's accounts files the audit there; a foreign account is 404" do
        patch api_v1_me_path(account_id: @another.to_param), headers: bearer(@tokens), as: :json, params: { first_name: "Narrowed" }
        assert_response :success
        assert_equal @another, AuditLog.where(user: @user).order(:id).last.account

        [ accounts(:regular_user_account).to_param, "not-an-id" ].each do |foreign|
          assert_no_difference -> { AuditLog.count } do
            patch api_v1_me_path(account_id: foreign), headers: bearer(@tokens), as: :json, params: { first_name: "Foreign" }
          end
          assert_response :not_found
          get api_v1_me_path(account_id: foreign), headers: bearer(@tokens)
          assert_response :not_found
          get api_v1_accounts_path(account_id: foreign), headers: bearer(@tokens)
          assert_response :not_found
        end
        assert_equal "Narrowed", @user.reload.first_name
      end

      # (c) A disabled account and a departed membership.
      test "a disabled account drops out of the list, is 404 when named and cannot become the default" do
        @team.update_columns(disabled_at: Time.current)
        assert_disabled_or_departed(@team)
      end

      test "a departed membership drops out of the list, is 404 when named and cannot become the default" do
        memberships(:team_member).destroy!
        assert_disabled_or_departed(@team)
      end

      test "an API key whose account is disabled, or whose person has left it, is 404" do
        key = ApiKey.generate_for(@user, name: "Team key", account: @team)
        headers = { "Authorization" => "Bearer #{key.raw_token}" }
        get api_v1_me_path, headers: headers
        assert_response :success, "precondition"

        @team.update_columns(disabled_at: Time.current)
        assert_key_refused(headers)

        @team.update_columns(disabled_at: nil)
        memberships(:team_member).destroy!
        assert_key_refused(headers)
      end

      test "an unconfirmed membership cannot become the default" do
        invited = Account.create!(name: "Invited team", account_type: :team)
        Membership.create!(account: invited, user: @user, role: "member", confirmed_at: nil)

        patch api_v1_me_path, headers: bearer(@tokens), as: :json, params: { default_account_id: invited.to_param }
        assert_response :unprocessable_entity
        assert_includes response.parsed_body.fetch("errors"), "Default account is not an account you belong to"
        assert_nil @user.reload.default_account_id
      end

      test "identity and discovery work when the chosen default account is disabled" do
        @user.update!(default_account_key: @team.to_param)
        @team.update_columns(disabled_at: Time.current)

        get api_v1_me_path, headers: bearer(@tokens)
        assert_response :success
        me = response.parsed_body.fetch("user")
        assert_not_includes me["accounts"].map { |a| a["id"] }, @team.to_param
        assert_includes [ @personal.to_param, @another.to_param ], me.dig("default_account", "id"),
          "falls back to a usable account, never the disabled one"

        patch api_v1_me_path, headers: bearer(@tokens), as: :json, params: { first_name: "Still me" }
        assert_response :success
        assert_not_equal @team, AuditLog.where(user: @user).order(:id).last.account
      end

      test "identity and discovery work when the person has no usable account at all" do
        [ @personal, @team, @another ].each { |account| account.update_columns(disabled_at: Time.current) }

        get api_v1_accounts_path, headers: bearer(@tokens)
        assert_response :success
        assert_equal [], response.parsed_body.fetch("accounts")

        get api_v1_me_path, headers: bearer(@tokens)
        assert_response :success
        assert_nil response.parsed_body.dig("user", "default_account")
        assert_equal [], response.parsed_body.dig("user", "accounts")

        patch api_v1_me_path, headers: bearer(@tokens), as: :json, params: { first_name: "Accountless" }
        assert_response :success
        log = AuditLog.where(user: @user).order(:id).last
        assert_nil log.account
        assert_equal @app_session.id, log.data["app_session_id"]
      end

      # (d)
      test "a resident key is 403 on every self endpoint" do
        headers = { "Authorization" => "Bearer #{ApiKey.generate_for(users(:user_1), name: 'Resident', agent: agents(:research_assistant)).raw_token}" }
        get api_v1_me_path, headers: headers
        assert_response :forbidden
        get api_v1_accounts_path, headers: headers
        assert_response :forbidden
        patch api_v1_me_path, headers: headers, as: :json, params: { first_name: "Hijack" }
        assert_response :forbidden
        delete api_v1_me_avatar_path, headers: headers
        assert_response :forbidden
      end

      private

      def assert_disabled_or_departed(account)
        get api_v1_accounts_path, headers: bearer(@tokens)
        assert_response :success
        assert_not_includes response.parsed_body.fetch("accounts").map { |a| a["id"] }, account.to_param

        get api_v1_me_path(account_id: account.to_param), headers: bearer(@tokens)
        assert_response :not_found
        assert_no_difference -> { AuditLog.count } do
          patch api_v1_me_path(account_id: account.to_param), headers: bearer(@tokens), as: :json, params: { first_name: "Gone" }
        end
        assert_response :not_found
        assert_not_equal "Gone", @user.reload.first_name

        patch api_v1_me_path, headers: bearer(@tokens), as: :json, params: { default_account_id: account.to_param }
        assert_response :unprocessable_entity
        assert_includes response.parsed_body.fetch("errors"), "Default account is not an account you belong to"
        assert_nil @user.reload.default_account_id
      end

      def assert_key_refused(headers)
        get api_v1_me_path, headers: headers
        assert_response :not_found
        get api_v1_accounts_path, headers: headers
        assert_response :not_found
        patch api_v1_me_path, headers: headers, as: :json, params: { first_name: "Departed" }
        assert_response :not_found
        assert_not_equal "Departed", @user.reload.first_name
      end

    end
  end
end
