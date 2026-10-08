require "test_helper"

module Api
  module V1
    class MeControllerTest < ActionDispatch::IntegrationTest

      setup do
        @user = users(:user_1)
        @account = accounts(:personal_account)
        @team = accounts(:team_account)
        @agent = agents(:research_assistant)
        @human_headers = headers_for(ApiKey.generate_for(@user, name: "Synthetic human", account: @account))
        @resident_headers = headers_for(ApiKey.generate_for(@user, name: "Synthetic resident", agent: @agent))
      end

      test "requires a key" do
        get api_v1_me_path
        assert_response :unauthorized
        patch api_v1_me_path, params: { first_name: "X" }, as: :json
        assert_response :unauthorized
        get api_v1_accounts_path
        assert_response :unauthorized
      end

      test "show returns the key's person, settings and confirmed accounts without secrets" do
        @user.profile.update!(timezone: "London", theme: "dark", theme_hue: 200, chat_colour: "teal")
        @user.update!(default_account_key: @team.to_param)

        get api_v1_me_path, headers: @human_headers

        assert_response :success
        me = response.parsed_body.fetch("user")
        assert_equal @user.to_param, me["id"]
        assert_equal "test@example.com", me["email_address"]
        assert_equal [ "Test", "User" ], me.values_at("first_name", "last_name")
        assert_equal [ "London", "dark", 200, "teal" ], me.values_at("timezone", "theme", "theme_hue", "chat_colour")
        assert_nil me["avatar_url"]
        assert_equal @team.to_param, me["default_account_id"]
        assert_equal({ "id" => @team.to_param, "name" => @team.name }, me["default_account"])
        expected = @user.confirmed_memberships.includes(:account).map do |m|
          { "id" => m.account.to_param, "name" => m.account.name, "type" => m.account.account_type, "role" => m.role }
        end
        assert_equal expected.sort_by { |a| a["id"] }, me["accounts"].sort_by { |a| a["id"] }
        assert_includes me["accounts"].map { |a| a["id"] }, @team.to_param
        assert_not_includes me["accounts"].map { |a| a["id"] }, accounts(:other).to_param
        body = response.body
        %w[password_digest password_reset_token raw_token token_digest].each { |secret| assert_not_includes body, secret }
      end

      test "update changes name timezone theme hue colour and default account and audits like the web" do
        assert_difference -> { AuditLog.where(user: @user, action: "change_theme").count }, 1 do
          patch api_v1_me_path, headers: @human_headers, as: :json, params: {
            first_name: "  Renamed ", last_name: "Person", timezone: "Tokyo", theme: "light",
            theme_hue: 42, chat_colour: "rose", default_account_id: @team.to_param
          }
        end

        assert_response :success
        @user.reload
        assert_equal [ "Renamed", "Person", "Tokyo", "light", 42, "rose" ],
          [ @user.first_name, @user.last_name, @user.timezone, @user.theme, @user.theme_hue, @user.chat_colour ]
        assert_equal @team.id, @user.default_account_id
        assert_equal "Renamed", response.parsed_body.dig("user", "first_name")
        log = AuditLog.where(user: @user).order(:id).last
        assert_equal @account, log.account
        assert_equal @user, log.auditable
      end

      test "update audit action follows the web rules" do
        patch api_v1_me_path, headers: @human_headers, as: :json, params: { timezone: "Paris" }
        assert_equal "update_timezone", AuditLog.where(user: @user).order(:id).last.action

        patch api_v1_me_path, headers: @human_headers, as: :json, params: { first_name: "Only" }
        assert_equal "update_profile", AuditLog.where(user: @user).order(:id).last.action
      end

      test "blank default account and blank hue clear the choice" do
        @user.update!(default_account_key: @team.to_param)
        @user.profile.update!(theme_hue: 10)

        patch api_v1_me_path, headers: @human_headers, as: :json, params: { default_account_id: nil, theme_hue: "" }

        assert_response :success
        assert_nil @user.reload.default_account_id
        assert_nil @user.theme_hue
        assert_nil response.parsed_body.dig("user", "default_account_id")
      end

      test "validation failures return 422 and change nothing" do
        [
          { theme: "neon" }, { theme_hue: 400 }, { chat_colour: "plaid" },
          { timezone: "Nowhere/Atlantis" }, { first_name: "" }
        ].each do |payload|
          assert_no_difference -> { AuditLog.count } do
            patch api_v1_me_path, headers: @human_headers, as: :json, params: payload
          end
          assert_response :unprocessable_entity, payload.inspect
          assert response.parsed_body.fetch("errors").any?, payload.inspect
        end
        assert_equal "Test", @user.reload.first_name
      end

      test "a default account the person does not belong to is refused" do
        [ accounts(:other).to_param, "not-an-id" ].each do |key|
          patch api_v1_me_path, headers: @human_headers, as: :json, params: { default_account_id: key }
          assert_response :unprocessable_entity
          assert_includes response.parsed_body.fetch("errors"), "Default account is not an account you belong to"
        end
        assert_nil @user.reload.default_account_id
      end

      test "password email and unknown fields are ignored" do
        digest = @user.password_digest
        patch api_v1_me_path, headers: @human_headers, as: :json,
          params: { email_address: "new@example.com", password: "newpassword123", site_admin: true, first_name: "Kept" }

        assert_response :success
        @user.reload
        assert_equal "test@example.com", @user.email_address
        assert_equal digest, @user.password_digest
        assert_not @user.is_site_admin
        assert_equal "Kept", @user.first_name
      end

      test "accounts lists the person's confirmed accounts and roles" do
        get api_v1_accounts_path, headers: @human_headers

        assert_response :success
        accounts = response.parsed_body.fetch("accounts")
        assert_includes accounts, { "id" => @account.to_param, "name" => @account.name, "type" => "personal", "role" => "owner" }
        assert_includes accounts, { "id" => @team.to_param, "name" => @team.name, "type" => @team.account_type, "role" => "owner" }
        assert_not_includes accounts.map { |a| a["id"] }, accounts(:other).to_param

        member_headers = headers_for(ApiKey.generate_for(users(:existing_user), name: "Member key"))
        get api_v1_accounts_path, headers: member_headers
        roles = response.parsed_body.fetch("accounts").to_h { |a| [ a["id"], a["role"] ] }
        assert_equal "member", roles[@team.to_param]
      end

      test "resident keys are refused on every self endpoint" do
        get api_v1_me_path, headers: @resident_headers
        assert_response :forbidden
        assert response.parsed_body["error"].present?

        patch api_v1_me_path, headers: @resident_headers, as: :json, params: { first_name: "Hijack" }
        assert_response :forbidden
        assert_equal "Test", @user.reload.first_name

        put api_v1_me_avatar_path, headers: @resident_headers,
          params: { avatar: fixture_file_upload("test_avatar.png", "image/png") }
        assert_response :forbidden
        assert_not @user.reload.avatar.attached?

        @user.avatar.attach(fixture_file_upload("test_avatar.png", "image/png"))
        delete api_v1_me_avatar_path, headers: @resident_headers
        assert_response :forbidden
        assert @user.reload.avatar.attached?

        get api_v1_accounts_path, headers: @resident_headers
        assert_response :forbidden
      end

      private

      def headers_for(key)
        { "Authorization" => "Bearer #{key.raw_token}" }
      end

    end
  end
end
