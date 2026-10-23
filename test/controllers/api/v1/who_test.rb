require "test_helper"

module Api
  module V1
    class WhoTest < ActionDispatch::IntegrationTest

      setup do
        @daniel = users(:user_1)
        @home = accounts(:personal_account)
        @nexus = accounts(:team_account)
        @agent = agents(:research_assistant) # home: personal_account
        @agent_headers = { "Authorization" => "Bearer #{ApiKey.generate_for(@daniel, name: "Agent", agent: @agent).raw_token}" }
        @account_headers = { "Authorization" => "Bearer #{ApiKey.generate_for(@daniel, name: "Account", account: @home).raw_token}" }
      end

      test "a resident sees who can read its home: every confirmed member, residents by seat, outside site admins" do
        @home.chats.create!(title: "Seated", model_id: "openrouter/auto", agents: [ @agent ])

        get api_v1_who_url, headers: @agent_headers
        assert_response :success
        body = response.parsed_body

        assert_equal @home.name, body.dig("account", "name")
        expected_people = @home.memberships.confirmed.includes(:user).map { |m| m.user.full_name.presence || "(no name set)" }.sort
        assert_equal expected_people, body["people"].map { |p| p["name"] }.sort
        assert body["people"].all? { |p| p["reads"] == AccessDirectory::READS_ALL && p["kind"] == "person" }

        mine = body["residents"].find { |r| r["id"] == @agent.to_param }
        assert_equal "resident", mine["kind"]
        assert_equal AccessDirectory::READS_SEATED, mine["reads"]
        assert_operator mine["seats"], :>=, 1

        member_ids = @home.memberships.confirmed.pluck(:user_id)
        if member_ids.exclude?(users(:site_admin_user).id)
          assert_includes body["site_admins"].map { |s| s["reads"] }, AccessDirectory.reads_any
        end
        assert_match(/Telegram/, body["not_covered"])
      end

      test "no email addresses appear" do
        get api_v1_who_url, headers: @agent_headers
        assert_response :success
        refute_match(/@example\.com/, response.body)
      end

      test "an unconfirmed invitation is not listed as a reader" do
        invitee = users(:regular_user)
        (invitee.profile || invitee.create_profile!).update!(first_name: "Pending", last_name: "Invitee")
        @home.memberships.where(user: invitee).delete_all
        Membership.insert!({ account_id: @home.id, user_id: invitee.id, role: "member", confirmed_at: nil,
          created_at: Time.current, updated_at: Time.current })

        get api_v1_who_url, headers: @agent_headers
        assert_response :success
        refute_includes response.parsed_body["people"].map { |p| p["name"] }, invitee.reload.full_name
      end

      test "a guest resident asks about the account it is seated in and is listed as a guest" do
        @nexus.guest_memberships.create!(agent: @agent, added_by: @daniel)

        get api_v1_who_url, params: { account_id: @nexus.to_param }, headers: @agent_headers
        assert_response :success
        assert_equal @nexus.name, response.parsed_body.dig("account", "name")
        mine = response.parsed_body["residents"].find { |r| r["id"] == @agent.to_param }
        assert_equal "guest_resident", mine["kind"]
      end

      test "a resident cannot ask about an account it has no seat in" do
        get api_v1_who_url, params: { account_id: @nexus.to_param }, headers: @agent_headers
        assert_response :not_found
      end

      test "a person's account key answers for that account" do
        get api_v1_who_url, headers: @account_headers
        assert_response :success
        assert_equal @home.name, response.parsed_body.dig("account", "name")
      end

      test "for one conversation: members with their role, then seats with the initiation setting" do
        peer = agents(:code_reviewer)
        chat = @home.chats.create!(title: "Who reads this", model_id: "openrouter/auto", agents: [ @agent, peer ])
        chat.chat_agents.find_by!(agent: peer).update!(closed_for_initiation_at: Time.current)

        get api_v1_conversation_who_url(chat), headers: @agent_headers
        assert_response :success
        body = response.parsed_body
        assert_equal "Who reads this", body.dig("conversation", "title")

        seats = body["readers"].select { |r| r["kind"] == "resident" }
        assert_equal [ @agent.name, peer.name ].sort, seats.map { |r| r["name"] }.sort
        assert seats.find { |r| r["id"] == peer.to_param }["closed_for_initiation"]
        refute seats.find { |r| r["id"] == @agent.to_param }["closed_for_initiation"]

        people = body["readers"].select { |r| r["kind"] == "person" }
        assert_equal @home.memberships.confirmed.count, people.size
        assert people.all? { |r| r["why"].start_with?("member of #{@home.name}") }
      end

      test "a resident cannot ask about a conversation it has no seat in" do
        chat = @home.chats.create!(title: "Not mine", model_id: "openrouter/auto", agents: [ agents(:code_reviewer) ])

        get api_v1_conversation_who_url(chat), headers: @agent_headers
        assert_response :not_found
      end

      test "a key whose owner has left the account gets nothing for a conversation" do
        chat = @home.chats.create!(title: "After leaving", model_id: "openrouter/auto")
        @home.memberships.where(user: @daniel).delete_all

        get api_v1_conversation_who_url(chat), headers: @account_headers
        assert_response :not_found
      end

      test "a key for a disabled account gets nothing for a conversation" do
        chat = @home.chats.create!(title: "Disabled", model_id: "openrouter/auto")
        @home.update_columns(disabled_at: Time.current)

        get api_v1_conversation_who_url(chat), headers: @account_headers
        assert_response :not_found
      end

      test "an inactive resident is still listed, because a seat and a key still read" do
        @agent.update_columns(active: false)
        @home.chats.create!(title: "Still seated", model_id: "openrouter/auto", agents: [ @agent ])

        get api_v1_who_url, headers: @account_headers
        assert_response :success
        mine = response.parsed_body["residents"].find { |r| r["id"] == @agent.to_param }
        assert mine, "inactive resident missing from the directory"
        assert_equal false, mine["active"]
        assert_operator mine["seats"], :>=, 1
      end

      test "a member's key can ask about any conversation in the account" do
        chat = @home.chats.create!(title: "Anyone's", model_id: "openrouter/auto")

        get api_v1_conversation_who_url(chat), headers: @account_headers
        assert_response :success
        assert_equal [], response.parsed_body["readers"].select { |r| r["kind"] == "resident" }
      end

    end
  end
end
