require "test_helper"

module Api
  module V1
    class ParticipantsControllerTest < ActionDispatch::IntegrationTest

      setup do
        @user = users(:user_1)
        @api_key = ApiKey.generate_for(@user, name: "Test")
        @token = @api_key.raw_token
        @account = @user.accounts.first
        @agent1 = agents(:research_assistant)
        @agent2 = agents(:code_reviewer)
        @agent3 = agents(:without_tools)

        @group_chat = Chat.create_with_message!(
          { account: @account, model_id: "openrouter/auto", title: "Group Chat", manual_responses: true },
          agent_ids: [ @agent1.id ]
        )

        @regular_chat = @account.chats.create!(
          model_id: "openrouter/auto",
          title: "Regular Chat"
        )
      end

      test "human removes last resident with audit and history preserved" do
        past = @group_chat.messages.create!(role: "assistant", agent: @agent1, content: "Keep me")
        assert_difference "AuditLog.where(action: 'remove_agent_from_chat').count", 1 do
          delete api_v1_conversation_participant_url(@group_chat),
            params: { agent_id: @agent1.to_param }, headers: { "Authorization" => "Bearer #{@token}" }
        end
        assert_response :no_content
        assert_empty @group_chat.agents.reload
        assert_equal @agent1, past.reload.agent
        audit = AuditLog.where(action: "remove_agent_from_chat").last
        assert_equal @api_key.id, audit.data["api_key_id"]
      end

      test "resident keys cannot remove anyone including themselves" do
        key = ApiKey.generate_for(@user, name: "Resident", agent: @agent1)
        delete api_v1_conversation_participant_url(@group_chat),
          params: { agent_id: @agent1.to_param }, headers: { "Authorization" => "Bearer #{key.raw_token}" }
        assert_response :forbidden
        assert @group_chat.agents.exists?(@agent1.id)
      end

      test "busy removal returns conflict and keeps the reservation" do
        run = AgentRuntimeInteraction.reserve!(agent: @agent1, chat: @group_chat)
        delete api_v1_conversation_participant_url(@group_chat),
          params: { agent_id: @agent1.to_param }, headers: { "Authorization" => "Bearer #{@token}" }
        assert_response :conflict
        assert_equal "already_responding", response.parsed_body["code"]
        assert_nil run.reload.finished_at
      end

      test "home owner withdraws a guest without receiving account membership" do
        receiving = accounts(:team_account)
        receiving.guest_memberships.create!(agent: @agent1, added_by: @user)
        chat = receiving.chats.create!(manual_responses: true, agents: [ @agent1, agents(:other_account_agent) ])
        @user.memberships.find_by!(account: receiving).update_columns(confirmed_at: nil)

        delete api_v1_conversation_participant_url(chat),
          params: { agent_id: @agent1.to_param }, headers: { "Authorization" => "Bearer #{@token}" }
        assert_response :no_content
        assert_not chat.agents.exists?(@agent1.id)
        assert receiving.guest_memberships.exists?(agent: @agent1), "withdraw just this room, not the account"
      end

      test "home owner cannot remove a different resident in a guest room" do
        receiving = accounts(:team_account)
        receiving.guest_memberships.create!(agent: @agent1, added_by: @user)
        local = agents(:other_account_agent)
        chat = receiving.chats.create!(manual_responses: true, agents: [ @agent1, local ])
        @user.memberships.find_by!(account: receiving).update_columns(confirmed_at: nil)

        delete api_v1_conversation_participant_url(chat),
          params: { agent_id: local.to_param }, headers: { "Authorization" => "Bearer #{@token}" }
        assert_response :forbidden
        assert chat.agents.exists?(local.id)
      end

      test "home key cannot edit other receiving residents even when its owner manages both accounts" do
        receiving = accounts(:team_account)
        receiving.guest_memberships.create!(agent: @agent1, added_by: @user)
        local = agents(:other_account_agent)
        chat = receiving.chats.create!(manual_responses: true, agents: [ @agent1, local ])
        assert receiving.manageable_by?(@user)

        delete api_v1_conversation_participant_url(chat),
          params: { agent_id: local.to_param }, headers: { "Authorization" => "Bearer #{@token}" }
        assert_response :forbidden
        assert chat.agents.exists?(local.id)
      end

      test "departed human cannot remove through an old key" do
        @user.memberships.find_by!(account: @account).update_columns(confirmed_at: nil)
        delete api_v1_conversation_participant_url(@group_chat),
          params: { agent_id: @agent1.to_param }, headers: { "Authorization" => "Bearer #{@token}" }
        assert_response :forbidden
      end

      test "adds agent to group chat" do
        post api_v1_conversation_participants_url(@group_chat),
             params: { agent_id: @agent2.to_param },
             headers: { "Authorization" => "Bearer #{@token}" }
        assert_response :created

        json = JSON.parse(response.body)
        assert_equal "Code Reviewer", json["participant"]["name"]
        assert_equal 2, json["agents"].length

        last_message = @group_chat.messages.last
        assert_match /Code Reviewer has joined/, last_message.content
      end

      test "rejects adding agent already in chat" do
        post api_v1_conversation_participants_url(@group_chat),
             params: { agent_id: @agent1.to_param },
             headers: { "Authorization" => "Bearer #{@token}" }
        assert_response :unprocessable_entity

        json = JSON.parse(response.body)
        assert_match /already in this conversation/, json["error"]
      end

      test "rejects adding to non-group chat" do
        post api_v1_conversation_participants_url(@regular_chat),
             params: { agent_id: @agent2.to_param },
             headers: { "Authorization" => "Bearer #{@token}" }
        assert_response :unprocessable_entity
      end

      test "rejects adding inactive agent" do
        inactive = agents(:inactive_agent)
        post api_v1_conversation_participants_url(@group_chat),
             params: { agent_id: inactive.to_param },
             headers: { "Authorization" => "Bearer #{@token}" }
        assert_response :not_found
      end

      test "rejects adding to archived chat" do
        @group_chat.archive!
        post api_v1_conversation_participants_url(@group_chat),
             params: { agent_id: @agent2.to_param },
             headers: { "Authorization" => "Bearer #{@token}" }
        assert_response :unprocessable_entity
      end

      test "returns unauthorized without token" do
        post api_v1_conversation_participants_url(@group_chat),
             params: { agent_id: @agent2.to_param }
        assert_response :unauthorized
      end

    end
  end
end
