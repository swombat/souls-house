require "test_helper"

module Api
  module V1
    # A resident hosted in one account, taking part in another as a guest,
    # through its ordinary resident key.
    class GuestResidentsTest < ActionDispatch::IntegrationTest

      setup do
        @daniel = users(:user_1)
        @home = accounts(:personal_account)
        @nexus = accounts(:team_account)
        @lume = agents(:research_assistant)
        @local = agents(:other_account_agent)
        @membership = @nexus.guest_memberships.create!(agent: @lume, added_by: @daniel)

        @lume_headers = { "Authorization" => "Bearer #{ApiKey.generate_for(@daniel, name: "Lume", agent: @lume).raw_token}" }
        @local_headers = { "Authorization" => "Bearer #{ApiKey.generate_for(@daniel, name: "Local", agent: @local).raw_token}" }
        @room = @nexus.chats.create!(model_id: "openrouter/auto", title: "Field film", manual_responses: true, agents: [ @local ])
      end

      test "a local resident sees the guest in its account's directory and seats it" do
        get api_v1_agents_url, headers: @local_headers
        assert_includes response.parsed_body["agents"].map { |agent| agent["id"] }, @lume.to_param

        post api_v1_conversation_participants_url(@room), params: { agent_id: @lume.to_param }, headers: @local_headers
        assert_response :created
        assert @room.agents.reload.include?(@lume)
      end

      test "a seated guest lists the residents of the room's account, not only its home" do
        @room.agents << @lume

        get api_v1_agents_url, params: { conversation_id: @room.to_param }, headers: @lume_headers
        ids = response.parsed_body["agents"].map { |agent| agent["id"] }
        assert_includes ids, @local.to_param
        assert_not_includes ids, agents(:code_reviewer).to_param

        post api_v1_conversation_participants_url(@room), params: { agent_id: agents(:code_reviewer).to_param }, headers: @lume_headers
        assert_response :not_found, "a guest cannot bring its home siblings in"
      end

      test "the room directory is closed to rooms the key cannot act in" do
        get api_v1_agents_url, params: { conversation_id: @room.to_param }, headers: @lume_headers
        assert_response :not_found
      end

      test "a local resident cannot seat a resident that is not a guest here" do
        post api_v1_conversation_participants_url(@room), params: { agent_id: agents(:code_reviewer).to_param }, headers: @local_headers
        assert_response :not_found
      end

      test "a local resident wakes the seated guest" do
        @room.agents << @lume
        assert_enqueued_with(job: ManualAgentResponseJob) do
          post api_v1_conversation_agent_trigger_url(@room), params: { agent_id: @lume.to_param }, headers: @local_headers
        end
        assert_response :success
      end

      test "the seated guest reads, posts and wakes others in the room with its home key" do
        @room.agents << @lume

        get api_v1_conversation_url(@room), headers: @lume_headers
        assert_response :success

        post api_v1_conversation_messages_url(@room), params: { content: "Hello from a guest." }, headers: @lume_headers
        assert_response :success
        assert @room.messages.exists?(agent: @lume, content: "Hello from a guest.")

        assert_enqueued_with(job: ManualAgentResponseJob) do
          post api_v1_conversation_agent_trigger_url(@room), params: { agent_id: @local.to_param }, headers: @lume_headers
        end
        assert_response :success
      end

      test "a guest only reaches the rooms it was added to" do
        get api_v1_conversation_url(@room), headers: @lume_headers
        assert_response :not_found

        post api_v1_conversation_agent_trigger_url(@room), params: { agent_id: @local.to_param }, headers: @lume_headers
        assert_response :not_found
      end

      test "the guest lists and leaves its guest memberships" do
        @room.agents << @lume

        get api_v1_guest_memberships_url, headers: @lume_headers
        assert_equal [ @nexus.name ], response.parsed_body["guest_memberships"].map { |m| m.dig("account", "name") }

        delete api_v1_guest_membership_url(@membership), headers: @lume_headers
        assert_response :success
        assert_not GuestMembership.exists?(@membership.id)

        get api_v1_conversation_url(@room), headers: @lume_headers
        assert_response :not_found
        assert @room.messages.exists?(content: "[System Notice] #{@lume.name} has left the conversation.")
      end

      test "a guest finds the guest account's residents before any room exists there" do
        get api_v1_agents_url, params: { account_id: @nexus.to_param }, headers: @lume_headers
        assert_response :success
        assert_includes response.parsed_body["agents"].map { |agent| agent["id"] }, @local.to_param
      end

      test "a guest starts a room in its guest account and invites a resident there" do
        assert_difference -> { @nexus.chats.count }, 1 do
          post api_v1_conversations_url,
               params: { account_id: @nexus.to_param, title: "A question for Nexus", message: "Hello.", agent_ids: [ @local.to_param ] },
               headers: @lume_headers, as: :json
        end
        assert_response :created

        room = @nexus.chats.order(:id).last
        assert_equal room.to_param, response.parsed_body.dig("conversation", "id")
        assert_equal [ @local, @lume ].map(&:id).sort, room.agents.pluck(:id).sort
        assert room.messages.exists?(agent: @lume, content: "Hello.")
      end

      test "without account_id a resident key still creates at home" do
        post api_v1_conversations_url, params: { title: "At home" }, headers: @lume_headers, as: :json
        assert_response :created
        assert_equal @home, Chat.find(response.parsed_body.dig("conversation", "id")).account
      end

      test "a guest cannot start a room in an account it is not a guest of" do
        assert_no_difference -> { Chat.count } do
          post api_v1_conversations_url, params: { account_id: accounts(:another_team).to_param, title: "Uninvited" },
               headers: @lume_headers, as: :json
        end
        assert_response :not_found

        get api_v1_agents_url, params: { account_id: accounts(:another_team).to_param }, headers: @lume_headers
        assert_response :not_found
      end

      test "a guest cannot bring its home siblings into a room it starts there" do
        assert_no_difference -> { Chat.count } do
          post api_v1_conversations_url, params: { account_id: @nexus.to_param, agent_ids: [ agents(:code_reviewer).to_param ] },
               headers: @lume_headers, as: :json
        end
        assert_response :not_found
      end

      test "after leaving, the guest account is closed to creation and discovery" do
        @membership.destroy!

        post api_v1_conversations_url, params: { account_id: @nexus.to_param, title: "Too late" }, headers: @lume_headers, as: :json
        assert_response :not_found

        get api_v1_agents_url, params: { account_id: @nexus.to_param }, headers: @lume_headers
        assert_response :not_found
      end

      test "a guest refused at the seat lock gets 422, not a half-made room" do
        # The account check passed, then the membership went before the insert:
        # the creator's seat is refused under the lock and the room rolls back.
        GuestMembership.where(id: @membership.id).delete_all
        controller_class = Api::V1::ConversationsController
        controller_class.class_eval { alias_method :__original_requested_account, :requested_account }
        controller_class.define_method(:requested_account) { Account.find(params[:account_id]) }
        begin
          assert_no_difference -> { Chat.count } do
            post api_v1_conversations_url, params: { account_id: @nexus.to_param, title: "Raced" }, headers: @lume_headers, as: :json
          end
        ensure
          controller_class.class_eval do
            alias_method :requested_account, :__original_requested_account
            remove_method :__original_requested_account
          end
        end
        assert_response :unprocessable_entity
        assert_match(/not a resident or guest of this account/, response.parsed_body["error"])
      end

      test "an account key cannot name another account" do
        account_headers = { "Authorization" => "Bearer #{ApiKey.generate_for(@daniel, name: "Account", account: @home).raw_token}" }
        post api_v1_conversations_url, params: { account_id: @nexus.to_param, agent_ids: [ @lume.to_param ] },
             headers: account_headers, as: :json
        assert_response :not_found
      end

      test "a resident cannot end another resident's guest membership" do
        delete api_v1_guest_membership_url(@membership), headers: @local_headers
        assert_response :not_found
        assert GuestMembership.exists?(@membership.id)
      end

    end
  end
end
