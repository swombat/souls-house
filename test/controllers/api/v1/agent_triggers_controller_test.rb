require "test_helper"

module Api
  module V1
    class AgentTriggersControllerTest < ActionDispatch::IntegrationTest

      setup do
        @user = users(:user_1)
        @api_key = ApiKey.generate_for(@user, name: "Test")
        @token = @api_key.raw_token
        @account = @user.accounts.first
        @agent1 = agents(:research_assistant)
        @agent2 = agents(:code_reviewer)

        @group_chat = Chat.create_with_message!(
          { account: @account, model_id: "openrouter/auto", title: "Group Chat", manual_responses: true },
          agent_ids: [ @agent1.id, @agent2.id ]
        )

        @regular_chat = @account.chats.create!(
          model_id: "openrouter/auto",
          title: "Regular Chat"
        )
      end

      test "triggers all agents in group chat" do
        assert_enqueued_with(job: AllAgentsResponseJob) do
          post api_v1_conversation_agent_trigger_url(@group_chat),
               headers: { "Authorization" => "Bearer #{@token}" }
        end
        assert_response :success

        json = JSON.parse(response.body)
        assert_equal 2, json["triggered"].length
      end

      test "triggers specific agent in group chat" do
        assert_enqueued_with(job: ManualAgentResponseJob) do
          post api_v1_conversation_agent_trigger_url(@group_chat),
               params: { agent_id: @agent1.to_param },
               headers: { "Authorization" => "Bearer #{@token}" }
        end
        assert_response :success

        json = JSON.parse(response.body)
        assert_equal 1, json["triggered"].length
        assert_equal "Research Assistant", json["triggered"].first["name"]
      end

      test "resident JSON request triggers only the named participant" do
        resident_token = ApiKey.generate_for(@user, name: "Resident", agent: @agent2).raw_token

        AgentRuntimeInteraction.stub :live_activity_enabled?, true do
          assert_difference -> { AgentRuntimeInteraction.count }, 1 do
            assert_enqueued_with(job: ManualAgentResponseJob, args: ->(args) { args.first(2) == [ @group_chat, @agent1 ] }) do
              post api_v1_conversation_agent_trigger_url(@group_chat),
                   params: { agent_id: @agent1.to_param },
                   headers: { "Authorization" => "Bearer #{resident_token}" }, as: :json
            end
          end
        end
        assert_response :success
        assert_equal [ { "id" => @agent1.to_param, "name" => @agent1.name } ], response.parsed_body["triggered"]
        assert_equal @agent1, @group_chat.agent_runtime_interactions.order(:id).last.agent
      end

      test "resident knock on a busy participant queues one wake, released when the run ends" do
        resident_token = ApiKey.generate_for(@user, name: "Resident", agent: @agent2).raw_token
        interaction = AgentRuntimeInteraction.reserve!(agent: @agent1, chat: @group_chat)

        AgentRuntimeInteraction.stub :live_activity_enabled?, true do
          assert_no_difference -> { AgentRuntimeInteraction.count } do
            assert_no_enqueued_jobs only: ManualAgentResponseJob do
              2.times do
                post api_v1_conversation_agent_trigger_url(@group_chat),
                     params: { agent_id: @agent1.to_param },
                     headers: { "Authorization" => "Bearer #{resident_token}" }, as: :json
                assert_response :success
              end
            end
          end
          assert_equal [], response.parsed_body["triggered"]
          assert_equal [ { "id" => @agent1.to_param, "name" => @agent1.name } ], response.parsed_body["queued"]
          wake = PendingWake.open.sole
          assert_equal [ 2, @agent2.name ], [ wake.requests_count, wake.requested_by ]
          @group_chat.messages.create!(role: "assistant", agent: @agent2, content: "Review: two findings.")

          assert_enqueued_with(job: PendingWakeJob, args: [ @group_chat.id, @agent1.id ]) do
            interaction.finish_execution!("completed")
          end
          assert_difference -> { AgentRuntimeInteraction.count }, 1 do
            perform_enqueued_jobs(only: PendingWakeJob)
          end
          released = @group_chat.agent_runtime_interactions.where(agent: @agent1).order(:id).last
          assert_equal released, wake.reload.released_interaction
          assert_not_nil wake.released_at
          assert_equal "queued", released.execution_state
        end
      end

      test "trigger all wakes the free participant and queues the busy one" do
        AgentRuntimeInteraction.reserve!(agent: @agent1, chat: @group_chat)

        assert_enqueued_with(job: AllAgentsResponseJob, args: [ @group_chat, [ @agent2.id ] ]) do
          post api_v1_conversation_agent_trigger_url(@group_chat),
               headers: { "Authorization" => "Bearer #{@token}" }, as: :json
        end
        assert_response :success
        assert_equal [ @agent2.to_param ], response.parsed_body["triggered"].map { |a| a["id"] }
        assert_equal [ @agent1.to_param ], response.parsed_body["queued"].map { |a| a["id"] }
        assert PendingWake.open.exists?(chat: @group_chat, agent: @agent1)
      end

      test "rejects trigger on non-group chat" do
        post api_v1_conversation_agent_trigger_url(@regular_chat),
             headers: { "Authorization" => "Bearer #{@token}" }
        assert_response :unprocessable_entity

        json = JSON.parse(response.body)
        assert_match /group chat/i, json["error"]
      end

      test "rejects trigger on archived chat" do
        @group_chat.archive!
        post api_v1_conversation_agent_trigger_url(@group_chat),
             headers: { "Authorization" => "Bearer #{@token}" }
        assert_response :unprocessable_entity
      end

      test "returns 404 for agent not in conversation" do
        other_agent = agents(:without_tools)
        post api_v1_conversation_agent_trigger_url(@group_chat),
             params: { agent_id: other_agent.to_param },
             headers: { "Authorization" => "Bearer #{@token}" }
        assert_response :not_found
      end

      test "returns unauthorized without token" do
        post api_v1_conversation_agent_trigger_url(@group_chat)
        assert_response :unauthorized
      end

      test "returns 404 for other account conversation" do
        other_user = users(:existing_user)
        other_account = other_user.accounts.first
        other_agent = agents(:other_account_agent)
        other_chat = Chat.create_with_message!(
          { account: other_account, model_id: "openrouter/auto", title: "Other Group", manual_responses: true },
          agent_ids: [ other_agent.id ]
        )

        post api_v1_conversation_agent_trigger_url(other_chat),
             headers: { "Authorization" => "Bearer #{@token}" }
        assert_response :not_found
      end

    end
  end
end
