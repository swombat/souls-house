require "test_helper"

module Api
  module V1
    class ConversationsUpdateTest < ActionDispatch::IntegrationTest

      setup do
        @user = users(:user_1)
        @account = @user.accounts.first
        @agent = agents(:research_assistant)
        @other_agent = agents(:code_reviewer)
        @agent_token = ApiKey.generate_for(@user, name: "Agent key", agent: @agent).raw_token
        @account_token = ApiKey.generate_for(@user, name: "Account key").raw_token
      end

      def room_with(agents, title: nil)
        chat = @account.chats.new(model_id: "openrouter/auto", title: title, manual_responses: true)
        chat.agent_ids = agents.map(&:id)
        chat.save!
        chat
      end

      def rename(chat, params, token: @agent_token)
        patch api_v1_conversation_url(chat), params: params, as: :json,
              headers: { "Authorization" => "Bearer #{token}" }
      end

      test "resident renames an untitled room it belongs to" do
        chat = room_with([ @agent ])

        rename(chat, { title: "  Call to action  " })

        assert_response :success
        assert_equal "Call to action", JSON.parse(response.body)["conversation"]["title"]
        assert_equal "Call to action", chat.reload.title
      end

      test "nested shape is refused instead of silently ignored" do
        chat = room_with([ @agent ], title: "Original")

        rename(chat, { conversation: { title: "Nested" } })

        assert_response :unprocessable_entity
        assert_equal "Original", chat.reload.title
      end

      test "blank, non-string and overlong titles are refused" do
        chat = room_with([ @agent ], title: "Original")

        [ "", "   ", 42, "x" * (ConversationsController::TITLE_MAX_LENGTH + 1) ].each do |bad|
          rename(chat, { title: bad })
          assert_response :unprocessable_entity, "expected 422 for #{bad.inspect}"
        end
        assert_equal "Original", chat.reload.title
      end

      test "resident cannot rename a room it is not in" do
        chat = room_with([ @other_agent ], title: "Not mine")

        rename(chat, { title: "Mine now" })

        assert_response :not_found
        assert_equal "Not mine", chat.reload.title
      end

      test "resident cannot add or remove the agent-only prefix" do
        open_room = room_with([ @agent ], title: "Open")
        rename(open_room, { title: "[AGENT-ONLY] Hidden" })
        assert_response :unprocessable_entity
        assert_not open_room.reload.agent_only?

        quiet_room = room_with([ @agent ], title: "[AGENT-ONLY] Quiet")
        rename(quiet_room, { title: "Loud" })
        assert_response :unprocessable_entity
        assert quiet_room.reload.agent_only?
      end

      test "resident may rename an agent-only room while keeping the prefix" do
        chat = room_with([ @agent ], title: "[AGENT-ONLY] Quiet")

        rename(chat, { title: "[AGENT-ONLY] Still quiet" })

        assert_response :success
        assert_equal "[AGENT-ONLY] Still quiet", chat.reload.title
      end

      test "account key may change the prefix, as the house UI can" do
        chat = room_with([ @agent ], title: "Open")

        rename(chat, { title: "[AGENT-ONLY] Hidden" }, token: @account_token)

        assert_response :success
        assert chat.reload.agent_only?
      end

    end
  end
end
