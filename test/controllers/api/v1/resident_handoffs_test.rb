require "test_helper"

# A resident's @Name tag wakes the resident it names, through the post itself;
# the receipt says whether the message reached them (MessageHandoff).
module Api
  module V1
    class ResidentHandoffsTest < ActionDispatch::IntegrationTest

      setup do
        @user = users(:confirmed_user)
        @account = @user.personal_account
        @account.update!(use_system_ai_credentials: false, openrouter_api_key: "test-only-router")
        @lume = @account.agents.create!(name: "Lume", system_prompt: "Test", runtime: "external")
        @mira = @account.agents.create!(name: "Mira", system_prompt: "Test", runtime: "external")
        @chat = @account.chats.new(model_id: "openrouter/auto", title: "Build", manual_responses: true)
        @chat.agents = [ @lume, @mira ]
        @chat.save!
        @lume_token = ApiKey.generate_for(@user, name: "Lume", agent: @lume).raw_token
        @human_token = ApiKey.generate_for(@user, name: "Daniel").raw_token
      end

      test "a resident's @Mira wakes Mira with no agent_trigger, and the receipt moves queued to delivered" do
        live do
          post_as_lume content: "@Mira ready for your re-review of the pinned head."
          assert_response :created
          assert_equal [ { "recipient_name" => "Mira", "state" => "queued" } ],
                       response.parsed_body["handoffs"].map { |r| r.slice("recipient_name", "state") }

          assert_difference -> { AgentRuntimeInteraction.where(agent: @mira, chat: @chat).count }, 1 do
            perform_enqueued_jobs(only: MessageHandoffJob)
          end
        end

        message = @chat.messages.where(agent: @lume).last
        run = @chat.agent_runtime_interactions.where(agent: @mira).sole
        run.update!(last_included_message_id: message.id, transport_status: 200, runtime_status: "ok")
        perform_enqueued_jobs(only: MessageHandoffSyncJob)

        get api_v1_conversation_url(@chat), headers: auth(@lume_token)
        entry = response.parsed_body.dig("conversation", "transcript").find { |m| m["id"] == message.to_param }
        assert_equal [ { "recipient_id" => @mira.to_param, "recipient_name" => "Mira", "state" => "delivered" } ],
                     entry["handoffs"].map { |r| r.slice("recipient_id", "recipient_name", "state") }
      end

      test "while Mira is busy the request is held, then released once with the message in her delta" do
        busy = AgentRuntimeInteraction.reserve!(agent: @mira, chat: @chat)
        live do
          post_as_lume content: "@Mira over to you"
          perform_enqueued_jobs(only: MessageHandoffJob)
        end
        message = @chat.messages.where(agent: @lume).last
        assert_equal "held", message.handoffs.sole.receipt_state

        busy.update_columns(last_included_message_id: message.id - 1, transport_status: 200, runtime_status: "ok")
        live do
          assert_difference -> { AgentRuntimeInteraction.where(agent: @mira).count }, 1 do
            busy.finish_execution!("completed")
            perform_enqueued_jobs(only: [ PendingWakeJob, MessageHandoffSyncJob ])
          end
        end
        released = @chat.agent_runtime_interactions.where(agent: @mira).order(:id).last
        request = ExternalAgentResponseRequest.new(agent: @mira, chat: @chat, interaction: released)
        assert_match(/Lume's message/, request.send(:queued_wake_text))
        assert_equal "queued", message.handoffs.sole.reload.receipt_state
      end

      test "agent_trigger after a tag for the same request creates no second run" do
        live do
          post_as_lume content: "@Mira ready"
          perform_enqueued_jobs(only: MessageHandoffJob)

          assert_no_difference -> { AgentRuntimeInteraction.count } do
            post api_v1_conversation_agent_trigger_url(@chat), params: { agent_id: @mira.to_param },
                 headers: auth(@lume_token), as: :json
          end
        end
        assert_response :success
        assert_equal [], response.parsed_body["triggered"]
        assert_equal [ @mira.to_param ], response.parsed_body["queued"].map { |a| a["id"] }
        assert_equal "queued", response.parsed_body["handoffs"].sole["state"]
      end

      test "a knock after the handoff was delivered wakes no one again" do
        message = nil
        live do
          post_as_lume content: "@Mira ready"
          perform_enqueued_jobs(only: MessageHandoffJob)
        end
        message = @chat.messages.where(agent: @lume).last
        run = @chat.agent_runtime_interactions.where(agent: @mira).sole
        run.update!(last_included_message_id: message.id, transport_status: 200, runtime_status: "ok")
        run.finish_execution!("completed")
        perform_enqueued_jobs(only: MessageHandoffSyncJob)
        assert_equal "delivered", message.handoffs.sole.reload.status

        live do
          assert_no_difference -> { AgentRuntimeInteraction.count } do
            knock agent_id: @mira.to_param
          end
        end
        assert_response :success
        body = response.parsed_body
        assert_equal [ [], [], [ @mira.to_param ] ], body.values_at("triggered", "queued", "skipped").map { |list| list.map { |a| a["id"] } }
        assert_equal "delivered", body["handoffs"].sole["state"]
      end

      test "a knock cannot get past a blocked handoff, through either entrance" do
        @account.update!(resident_handoff_cap: 0)
        post_as_lume content: "@Mira anyone?"
        assert_equal "handoffs_off", response.parsed_body["handoffs"].sole["reason"]

        live do
          assert_no_difference -> { AgentRuntimeInteraction.count } do
            assert_no_enqueued_jobs(only: AllAgentsResponseJob) do
              knock agent_id: @mira.to_param
              assert_equal [ @mira.to_param ], response.parsed_body["skipped"].map { |a| a["id"] }

              @chat.agents.delete(@lume)
              knock
            end
          end
        end
        assert_response :success
        assert_equal [ @mira.to_param ], response.parsed_body["skipped"].map { |a| a["id"] }
        assert_equal "blocked", response.parsed_body["handoffs"].sole["state"]
      end

      test "knocking everyone leaves out a resident the post already handed off to and wakes the rest" do
        third = @account.agents.create!(name: "Wren", system_prompt: "Test", runtime: "external")
        @chat.agents << third
        live do
          post_as_lume content: "@Mira ready"
          perform_enqueued_jobs(only: MessageHandoffJob)

          assert_enqueued_with(job: AllAgentsResponseJob, args: ->(args) { !args.last.include?(@mira.id) && args.last.include?(third.id) }) do
            knock
          end
        end
        assert_response :success
        assert_equal [ @mira.to_param ], response.parsed_body["queued"].map { |a| a["id"] }
        assert_includes response.parsed_body["triggered"].map { |a| a["id"] }, third.to_param
      end

      test "a knock after a later post that tagged no one is a new request, and message_id ties a knock to its post" do
        live do
          post_as_lume content: "@Mira ready"
          perform_enqueued_jobs(only: MessageHandoffJob)
        end
        tagged = @chat.messages.where(agent: @lume).last
        run = @chat.agent_runtime_interactions.where(agent: @mira).sole
        run.update!(last_included_message_id: tagged.id, transport_status: 200, runtime_status: "ok")
        run.finish_execution!("completed")
        perform_enqueued_jobs(only: MessageHandoffSyncJob)

        post_as_lume content: "One more thing, untagged."
        live do
          knock agent_id: @mira.to_param, message_id: tagged.to_param
          assert_equal [ @mira.to_param ], response.parsed_body["skipped"].map { |a| a["id"] }

          assert_difference -> { AgentRuntimeInteraction.where(agent: @mira).count }, 1 do
            knock agent_id: @mira.to_param
          end
        end
        assert_equal [ @mira.to_param ], response.parsed_body["triggered"].map { |a| a["id"] }

        knock agent_id: @mira.to_param, message_id: Message.where(role: "user").first&.to_param || "nope"
        assert_response :unprocessable_entity
      end

      test "a tag inside a code block or a quote wakes no one" do
        assert_no_enqueued_jobs(only: MessageHandoffJob) do
          post_as_lume content: "Use this:\n\n```\n@Mira please review\n```"
          post_as_lume content: "> @Mira said it was fine"
        end
        assert_response :created
        assert_equal [], response.parsed_body["handoffs"]
      end

      test "recipient_agent_ids hands off without a tag, and must name residents in the room" do
        assert_enqueued_with(job: MessageHandoffJob) do
          post_as_lume content: "Review is ready.", recipient_agent_ids: [ @mira.to_param ]
        end
        assert_equal "field", response.parsed_body["handoffs"].sole["source"]

        outsider = @account.agents.create!(name: "Elsewhere", system_prompt: "Test", runtime: "external")
        assert_no_difference -> { Message.count } do
          post_as_lume content: "Hello", recipient_agent_ids: [ outsider.to_param ]
        end
        assert_response :unprocessable_entity

        post_as_lume content: "Hello again", recipient_agent_ids: "not-a-list"
        assert_response :unprocessable_entity
      end

      test "a person's key may not send recipient_agent_ids" do
        post api_v1_conversation_messages_url(@chat), params: { content: "Hi", recipient_agent_ids: [ @mira.to_param ] },
             headers: auth(@human_token), as: :json
        assert_response :unprocessable_entity
      end

      test "the loop cap blocks the request and says so in the room" do
        @account.update!(resident_handoff_cap: 1)
        post_as_lume content: "@Mira first"
        assert_difference -> { @chat.messages.where(role: "system").count }, 1 do
          post_as_lume content: "@Mira second"
        end
        assert_equal [ "blocked", "loop_cap" ], response.parsed_body["handoffs"].sole.values_at("state", "reason")
      end

      test "a resident opening a conversation with a tag hands off to the invited resident" do
        assert_enqueued_with(job: MessageHandoffJob) do
          post api_v1_conversations_url,
               params: { account_id: @account.to_param, agent_ids: [ @mira.to_param ], title: "New", message: "@Mira a fresh room for the review" },
               headers: auth(@lume_token), as: :json
        end
        assert_response :created
        chat = Chat.find_by_obfuscated_id(response.parsed_body.dig("conversation", "id"))
        assert_equal [ @mira.id ], chat.messages.sole.handoffs.pluck(:recipient_agent_id)
      end

      private

      def post_as_lume(**params)
        post api_v1_conversation_messages_url(@chat), params: params, headers: auth(@lume_token), as: :json
      end

      def knock(**params)
        post api_v1_conversation_agent_trigger_url(@chat), params: params, headers: auth(@lume_token), as: :json
      end

      def auth(token)
        { "Authorization" => "Bearer #{token}" }
      end

      def live(&block)
        AgentRuntimeInteraction.stub(:live_activity_enabled?, true, &block)
      end

    end
  end
end
