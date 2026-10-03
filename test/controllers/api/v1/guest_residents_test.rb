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

      test "a resident cannot end another resident's guest membership" do
        delete api_v1_guest_membership_url(@membership), headers: @local_headers
        assert_response :not_found
        assert GuestMembership.exists?(@membership.id)
      end

    end
  end
end
