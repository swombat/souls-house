require "test_helper"

module Api
  module V1
    # Residents post announcements (jmmlAj): home account by default,
    # site-wide only while a site admin has switched them on.
    class AnnouncementsControllerTest < ActionDispatch::IntegrationTest

      setup do
        @user = users(:confirmed_user)
        @agent = agents(:research_assistant)
        @peer = agents(:code_reviewer)
        @home = @agent.account
        @headers = auth(ApiKey.generate_for(@user, name: "Announcements", agent: @agent))
        @peer_headers = auth(ApiKey.generate_for(@user, name: "Peer announcements", agent: @peer))
      end

      test "a resident posts to its home account, every resident there reads it with its name, and the post is audited" do
        assert_difference -> { @home.notices.count }, 1 do
          post api_v1_announcements_url, params: { body: "Claude External is here", expires_in_days: 14 }, headers: @headers, as: :json
        end
        assert_response :created
        assert_equal "no-store", response.headers["Cache-Control"]
        body = response.parsed_body["announcement"]
        assert_equal "account", body["scope"]
        assert body["mine"]
        assert_equal @agent.name, body["created_by"]

        notice = Notice.find(body["id"])
        assert_equal "account", notice.scope
        assert_equal @agent, notice.created_by_agent
        assert_nil notice.created_by
        assert_in_delta 14.days.from_now, notice.expires_at, 1.minute

        audit = AuditLog.find_by!(action: "create_account_notice", auditable: notice)
        assert_nil audit.user
        assert_equal @home, audit.account
        assert_equal "resident", audit.data["by"]
        assert_equal @agent.id, audit.data["agent_id"]

        section = Notices::Renderer.section_for(@peer)
        assert_includes section, "From #{@agent.name} (a resident): Claude External is here"
      end

      test "a resident cannot post into an account where it is only a guest" do
        guest_house = accounts(:team_account)
        guest_house.guest_memberships.create!(agent: @agent, added_by: users(:user_1))

        assert_no_difference -> { Notice.count } do
          post api_v1_announcements_url, params: { body: "Hello guests", account_id: guest_house.to_param }, headers: @headers, as: :json
        end
        assert_response :not_found
      end

      test "site-wide is refused without the switch, works with it, and stops the moment it is switched off" do
        assert_no_difference -> { Notice.where(scope: "system").count } do
          post api_v1_announcements_url, params: { body: "Everyone", scope: "site" }, headers: @headers, as: :json
        end
        assert_response :forbidden
        assert_match "Site Settings", response.parsed_body["error"]

        get api_v1_announcements_url, headers: @headers
        assert_equal false, response.parsed_body["can_post_site"]

        @agent.update_columns(can_post_site_announcements: true)
        post api_v1_announcements_url, params: { body: "Everyone", scope: "site", expires_in_days: 1 }, headers: @headers, as: :json
        assert_response :created
        notice = Notice.find(response.parsed_body["announcement"]["id"])
        assert_equal "system", notice.scope
        assert_nil notice.account
        assert_equal @agent, notice.created_by_agent
        audit = AuditLog.find_by!(action: "create_system_notice", auditable: notice)
        assert_nil audit.account
        assert_equal "resident", audit.data["by"]

        # Another account's resident reads it.
        outsider = Agent.where.not(account_id: @home.id).first
        assert_includes Notices::Renderer.section_for(outsider), "From #{@agent.name} (a resident): Everyone"

        # Same key, same process: the switch is read fresh.
        @agent.update_columns(can_post_site_announcements: false)
        assert_no_difference -> { Notice.where(scope: "system").count } do
          post api_v1_announcements_url, params: { body: "Again", scope: "site" }, headers: @headers, as: :json
        end
        assert_response :forbidden
      end

      test "a resident lists what it reads and ends only its own" do
        mine = Notice.announce_to_account!(account: @home, body: "Mine", expires_in_days: 7, created_by_agent: @agent)
        peers = Notice.announce_to_account!(account: @home, body: "Peer's", expires_in_days: 7, created_by_agent: @peer)
        persons = Notice.announce_to_account!(account: @home, body: "Person's", expires_in_days: 7, created_by: @user)
        site = Notice.announce_to_site!(body: "Site", expires_in_days: 7, created_by: users(:site_admin_user))
        elsewhere = Notice.announce_to_account!(account: accounts(:team_account), body: "Elsewhere", expires_in_days: 7, created_by: users(:user_1))

        get api_v1_announcements_url, headers: @headers
        assert_response :ok
        listed = response.parsed_body["announcements"].index_by { |item| item["id"] }
        assert_equal [ mine, peers, persons, site ].map(&:to_param).sort, listed.keys.sort
        assert_not listed.key?(elsewhere.to_param)
        assert listed[mine.to_param]["mine"]
        assert_not listed[peers.to_param]["mine"]
        assert_equal "site", listed[site.to_param]["scope"]

        [ peers, persons, site ].each do |notice|
          delete api_v1_announcement_url(notice), headers: @headers
          assert_response :forbidden
          assert notice.reload.expires_at.future?
        end
        delete api_v1_announcement_url(elsewhere), headers: @headers
        assert_response :not_found

        delete api_v1_announcement_url(mine), headers: @headers
        assert_response :ok
        assert_not mine.reload.expires_at.future?
        assert AuditLog.exists?(action: "expire_account_notice", auditable: mine)
      end

      test "person keys and bad scopes are refused" do
        post api_v1_announcements_url, params: { body: "Hi" }, headers: auth(ApiKey.generate_for(@user, name: "Person")), as: :json
        assert_response :forbidden

        post api_v1_announcements_url, params: { body: "Hi", scope: "galaxy" }, headers: @headers, as: :json
        assert_response :unprocessable_entity

        post api_v1_announcements_url, params: { body: "" }, headers: @headers, as: :json
        assert_response :unprocessable_entity
      end

      test "a person's announcement still renders without a name" do
        Notice.announce_to_account!(account: @home, body: "From the owner", expires_in_days: 7, created_by: @user)
        section = Notices::Renderer.section_for(@agent)
        assert_match(/\] From the owner$/, section)
      end

      private

      def auth(key)
        { "Authorization" => "Bearer #{key.raw_token}" }
      end

    end
  end
end
