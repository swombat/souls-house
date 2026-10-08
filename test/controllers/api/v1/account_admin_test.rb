require "test_helper"

module Api
  module V1
    # The account itself, members and invitations, notices, costs and access
    # keys, with a person's key (issue: agent-drivable account admin).
    class AccountAdminTest < ActionDispatch::IntegrationTest

      setup do
        @team = accounts(:team)
        @owner_headers = headers_for(ApiKey.generate_for(users(:owner), name: "Owner agent", account: @team))
        @admin_headers = headers_for(ApiKey.generate_for(users(:admin), name: "Admin agent", account: @team))
        @member_headers = headers_for(ApiKey.generate_for(users(:member), name: "Member agent", account: @team))
        @personal = accounts(:personal_account)
        @daniel_headers = headers_for(ApiKey.generate_for(users(:user_1), name: "Daniel's agent", account: @personal))
        @resident_headers = headers_for(ApiKey.generate_for(users(:user_1), name: "Resident", agent: agents(:research_assistant)))
      end

      # Account

      test "shows the account with members and pending invitations, without tokens" do
        get api_v1_account_path, headers: @member_headers

        assert_response :success
        account = response.parsed_body.fetch("account")
        assert_equal @team.to_param, account["id"]
        assert_equal "team", account["account_type"]
        assert_equal Account::LOGO_COLOURS, account["logo_colour_options"]
        assert_equal %w[teamadmin@example.com teammember@example.com teamowner@example.com],
          account["members"].map { |member| member.dig("user", "email_address") }.sort
        assert_equal [ "othermember@example.com" ], account["pending_invitations"].map { |member| member.dig("user", "email_address") }
        assert_equal "invited", account["pending_invitations"].first["status"]
        owner = account["members"].find { |member| member["role"] == "owner" }
        assert_equal false, owner["can_remove"], "the last owner can't be removed"
        assert_not_includes response.body, "confirmation_token"
        assert_not_includes response.body, memberships(:pending_team_invitation).confirmation_token
      end

      test "the account endpoints refuse a resident key" do
        get api_v1_account_path, headers: @resident_headers
        assert_response :forbidden
        assert_match(/person's API key/, response.parsed_body["error"])

        patch api_v1_account_path, params: { name: "Renamed by resident" }, headers: @resident_headers, as: :json
        assert_response :forbidden
        assert_equal "Test User's Account", @personal.reload.name
      end

      test "another account is not found, and the key's own account may be named" do
        get api_v1_account_path, params: { account_id: @personal.to_param }, headers: @member_headers
        assert_response :not_found

        get api_v1_account_path, params: { account_id: @team.to_param }, headers: @member_headers
        assert_response :success
      end

      test "a key whose person has left the account no longer reaches it" do
        memberships(:team_member_user).destroy!

        get api_v1_account_path, headers: @member_headers
        assert_response :not_found
      end

      test "renames the account and sets the logo colour, with the web's audit entries" do
        assert_difference -> { AuditLog.where(action: %w[update_account_settings update_account_logo_colour]).count }, 2 do
          patch api_v1_account_path, params: { name: "Renamed Team", logo_colour: "plum" }, headers: @member_headers, as: :json
        end

        assert_response :success
        assert_equal "Renamed Team", response.parsed_body.dig("account", "name")
        assert_equal "plum", @team.reload.logo_colour
        rename = AuditLog.find_by!(action: "update_account_settings")
        assert_equal [ "Team for Testing", "Renamed Team" ], rename.data["name"]
        assert_equal users(:member), rename.user
        assert_equal @team, rename.account

        patch api_v1_account_path, params: { logo_colour: nil }, headers: @member_headers, as: :json
        assert_response :success
        assert_nil @team.reload.logo_colour
      end

      test "an invalid change saves nothing" do
        assert_no_difference -> { AuditLog.count } do
          patch api_v1_account_path, params: { name: "Half done", logo_colour: "neon" }, headers: @member_headers, as: :json
        end
        assert_response :unprocessable_entity
        assert response.parsed_body.dig("errors", "logo_colour").present?
        assert_equal "Team for Testing", @team.reload.name

        patch api_v1_account_path, params: { name: "" }, headers: @member_headers, as: :json
        assert_response :unprocessable_entity

        patch api_v1_account_path, params: { account_type: "personal" }, headers: @owner_headers, as: :json
        assert_response :unprocessable_entity
        assert @team.reload.team?, "converting the account type is not offered"
      end

      # Invitations and members

      test "invites someone, with the web's audit entry" do
        assert_difference -> { @team.memberships.pending_invitations.count }, 1 do
          post api_v1_account_invitations_path, params: { email: "newcomer@example.com", role: "member" }, headers: @admin_headers, as: :json
        end

        assert_response :created
        assert_equal "invited", response.parsed_body.dig("invitation", "status")
        log = AuditLog.find_by!(action: "invite_member")
        assert_equal({ "invited_email" => "newcomer@example.com", "role" => "member" }, log.data.except("api_key_id"))
        assert_equal users(:admin), log.user
      end

      test "an invalid invitation is refused with the model's errors" do
        post api_v1_account_invitations_path, params: { email: "newcomer@example.com", role: "emperor" }, headers: @admin_headers, as: :json
        assert_response :unprocessable_entity
        assert response.parsed_body.dig("errors", "role").present?

        post api_v1_account_invitations_path, params: { email: "teammember@example.com", role: "member" }, headers: @admin_headers, as: :json
        assert_response :unprocessable_entity

        post api_v1_account_invitations_path, params: { email: "friend@example.com", role: "member" }, headers: @daniel_headers, as: :json
        assert_response :unprocessable_entity, "personal accounts can't invite"
      end

      test "resends a pending invitation but not a confirmed membership" do
        pending = memberships(:pending_team_invitation)
        post resend_api_v1_account_invitation_path(pending), headers: @member_headers
        assert_response :success
        assert AuditLog.exists?(action: "resend_invitation", auditable: pending)

        post resend_api_v1_account_invitation_path(memberships(:team_member_user)), headers: @member_headers
        assert_response :unprocessable_entity

        post resend_api_v1_account_invitation_path(memberships(:pending_invitation)), headers: @member_headers
        assert_response :not_found, "another account's invitation"
      end

      test "removes a member, with the web's audit entry" do
        assert_difference -> { @team.memberships.count }, -1 do
          delete api_v1_account_member_path(memberships(:team_member_user)), headers: @admin_headers
        end

        assert_response :success
        log = AuditLog.find_by!(action: "remove_member")
        assert_equal({ "removed_email" => "teammember@example.com", "removed_role" => "member" }, log.data.except("api_key_id"))
      end

      test "keeps the web's rules: not yourself, not the last owner, not another account's member" do
        delete api_v1_account_member_path(memberships(:team_admin_member)), headers: @admin_headers
        assert_response :unprocessable_entity
        assert_equal "You can't remove yourself from this account", response.parsed_body["error"]

        delete api_v1_account_member_path(memberships(:team_owner)), headers: @admin_headers
        assert_response :unprocessable_entity
        assert_equal "Cannot remove the last owner", response.parsed_body["error"]

        delete api_v1_account_member_path(memberships(:team_member)), headers: @admin_headers
        assert_response :not_found
        assert Membership.exists?(memberships(:team_member).id)
      end

      # Notices

      test "posts, lists and ends account notices" do
        post api_v1_account_notices_path, params: { body: "Quiet hours tonight", expires_in_days: 3 }, headers: @member_headers, as: :json
        assert_response :created
        notice = @team.notices.last
        assert_in_delta 3.days.from_now, notice.expires_at, 1.minute
        assert_equal users(:member), notice.created_by
        assert AuditLog.exists?(action: "create_account_notice", auditable: notice)

        get api_v1_account_notices_path, headers: @member_headers
        assert_response :success
        assert_equal [ notice.to_param ], response.parsed_body["notices"].map { |item| item["id"] }

        delete api_v1_account_notice_path(notice), headers: @member_headers
        assert_response :success
        assert_not Notice.active.exists?(notice.id)
        assert AuditLog.exists?(action: "expire_account_notice", auditable: notice)

        delete api_v1_account_notice_path(notice), headers: @member_headers
        assert_response :not_found
      end

      test "notices fall back to a week, refuse a blank body, and stay in their account" do
        post api_v1_account_notices_path, params: { body: "Hello", expires_in_days: 99 }, headers: @member_headers, as: :json
        assert_in_delta 7.days.from_now, @team.notices.last.expires_at, 1.minute

        post api_v1_account_notices_path, params: { body: "" }, headers: @member_headers, as: :json
        assert_response :unprocessable_entity

        elsewhere = Notice.announce_to_account!(account: @personal, body: "Elsewhere", expires_in_days: 7, created_by: users(:user_1))
        delete api_v1_account_notice_path(elsewhere), headers: @member_headers
        assert_response :not_found
      end

      # Costs

      test "reads account, resident and conversation costs from the web's reports" do
        Setting.instance.update!(allow_agents: true, allow_chats: true)
        chat = @personal.chats.create!(title: "Costed", model_id: "openrouter/auto")

        get api_v1_account_costs_path, headers: @daniel_headers
        assert_response :success
        assert response.parsed_body.fetch("cost_report").key?("agent_totals")

        get agent_costs_api_v1_account_path(agents(:research_assistant)), headers: @daniel_headers
        assert_response :success
        assert_equal "Research Assistant", response.parsed_body.dig("agent", "name")
        assert response.parsed_body.fetch("cost_report").key?("days")

        get conversation_costs_api_v1_account_path(chat), headers: @daniel_headers
        assert_response :success
        assert response.parsed_body.fetch("cost_breakdown").key?("totals")

        get agent_costs_api_v1_account_path(agents(:other_account_agent)), headers: @daniel_headers
        assert_response :not_found
        get conversation_costs_api_v1_account_path(accounts(:team_account).chats.create!(title: "Theirs", model_id: "openrouter/auto")),
          headers: @daniel_headers
        assert_response :not_found
        get api_v1_account_costs_path, headers: @resident_headers
        assert_response :forbidden
      end

      test "costs follow the web's feature switch" do
        Setting.instance.update!(allow_agents: false)
        get api_v1_account_costs_path, headers: @daniel_headers
        assert_response :forbidden
      end

      # External access keys

      test "lists key metadata only and revokes only your own keys" do
        own = ApiKey.generate_for(users(:member), name: "Spare", account: @team)
        colleague = ApiKey.generate_for(users(:admin), name: "Colleague's", account: @team)

        get api_v1_account_api_keys_path, headers: @member_headers
        assert_response :success
        names = response.parsed_body["external_access_keys"].map { |key| key["name"] }
        assert_equal [ "Member agent", "Spare" ], names.sort
        assert_equal [ true ], response.parsed_body["external_access_keys"].select { |key| key["current"] }.map { |key| key["current"] }
        assert_not_includes response.body, own.token_digest
        assert_not_includes response.body, own.raw_token
        assert_not_includes response.body, "token_digest"

        delete api_v1_account_api_key_path(colleague), headers: @member_headers
        assert_response :not_found
        assert ApiKey.exists?(colleague.id)

        delete api_v1_account_api_key_path(own), headers: @member_headers
        assert_response :success
        assert_not ApiKey.exists?(own.id)
      end

      test "lists the account's resident keys" do
        get api_v1_account_api_keys_path, headers: @daniel_headers
        assert_response :success
        assert_equal [ "Research Assistant" ], response.parsed_body["resident_access_keys"].map { |key| key.dig("actor", "name") }
      end

      private

      def headers_for(key)
        { "Authorization" => "Bearer #{key.raw_token}" }
      end

    end
  end
end
