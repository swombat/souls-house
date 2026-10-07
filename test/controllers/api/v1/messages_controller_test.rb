require "test_helper"

module Api
  module V1
    class MessagesControllerTest < ActionDispatch::IntegrationTest

      setup do
        @user = users(:confirmed_user)
        @api_key = ApiKey.generate_for(@user, name: "Test")
        @token = @api_key.raw_token
        @account = @user.personal_account
        @account.update!(use_system_ai_credentials: false, openrouter_api_key: "test-only-router")
        @chat = @account.chats.create!(model_id: "openrouter/auto", title: "Test Chat")
      end

      test "human API message wakes the only resident and reports the trigger" do
        resident = @account.agents.create!(name: "Solo", system_prompt: "Test", runtime: "external")
        @chat.agents << resident
        @chat.update!(manual_responses: true)

        assert_enqueued_jobs 1, only: ManualAgentResponseJob do
          post api_v1_conversation_messages_url(@chat),
            params: { content: "Hello resident" },
            headers: { "Authorization" => "Bearer #{@token}" }
        end
        assert_response :created
        assert JSON.parse(response.body)["ai_response_triggered"]
        assert_equal "queued", @chat.agent_runtime_interactions.sole.execution_state
      end

      test "creates message without triggering retired inline inference" do
        @chat.messages.create!(content: "Hello", role: "user", user: @user)

        assert_no_enqueued_jobs(only: AiResponseJob) do
          post api_v1_conversation_messages_url(@chat),
               params: { content: "New message" },
               headers: { "Authorization" => "Bearer #{@token}" }
        end
        assert_response :created

        json = JSON.parse(response.body)
        assert json["message"]["id"].present?
        assert_equal "New message", json["message"]["content"]
        assert_not json["ai_response_triggered"]
      end

      test "agent-scoped key posts assistant message as agent" do
        agent = agents(:research_assistant)
        agent.update_columns(account_id: @account.id) # seat a resident hosted in this room's account
        agent_key = ApiKey.generate_for(@user, name: "Agent postback", agent: agent)
        @chat.agents << agent
        @chat.update!(manual_responses: true)

        assert_difference "Message.count", 1 do
          post api_v1_conversation_messages_url(@chat),
            params: { content: "External reply" },
            headers: { "Authorization" => "Bearer #{agent_key.raw_token}" }
        end

        assert_response :created
        message = @chat.messages.order(:created_at).last
        assert_equal "assistant", message.role
        assert_equal agent, message.agent
        assert_nil message.user
      end

      test "agent-scoped key posts an image attachment" do
        agent = agents(:research_assistant)
        agent.update_columns(account_id: @account.id) # seat a resident hosted in this room's account
        agent_key = ApiKey.generate_for(@user, name: "Agent image postback", agent: agent)
        @chat.agents << agent
        @chat.update!(manual_responses: true)

        post api_v1_conversation_messages_url(@chat),
          params: {
            content: "A generated test image",
            files: [ fixture_file_upload("test_image.png", "image/png") ]
          },
          headers: { "Authorization" => "Bearer #{agent_key.raw_token}" }

        assert_response :created
        message = @chat.messages.order(:created_at).last
        assert_equal agent, message.agent
        assert message.attachments.attached?
        assert message.completed?
        assert_equal "test_image.png", message.attachments.first.filename.to_s

        json = JSON.parse(response.body)
        file = json.dig("message", "files_json", 0)
        assert_equal "test_image.png", file["filename"]
        assert_equal "image/png", file["content_type"]
        assert file["url"].present?
        assert file["thumb_url"].present?
        assert file["preview_url"].present?
      end

      test "normalizes resident JSON prose but preserves code examples and source links" do
        marker = "\uE200cite\uE202turn0search2\uE202turn0search0\uE201"
        content = "Evidence#{marker} [source](https://example.org/source)\n`#{marker}`\n```\n#{marker}\n```"
        expected = "Evidence [source](https://example.org/source)\n`#{marker}`\n```\n#{marker}\n```"

        post api_v1_conversation_messages_url(@chat),
          params: { content: content },
          headers: resident_headers,
          as: :json

        assert_response :created
        assert_equal expected, @chat.messages.last.content
        assert_equal expected, JSON.parse(response.body).dig("message", "content")
      end

      test "normalizes resident multipart content and keeps the attachment" do
        marker = "\uE200cite\uE202turn0search2\uE201"

        post api_v1_conversation_messages_url(@chat),
          params: {
            content: "An image#{marker}",
            files: [ fixture_file_upload("test_image.png", "image/png") ]
          },
          headers: resident_headers

        assert_response :created
        assert_equal "An image", @chat.messages.last.content
        assert @chat.messages.last.attachments.attached?
        assert_equal "An image", JSON.parse(response.body).dig("message", "content")
      end

      test "human API content is unchanged for JSON and multipart posts" do
        content = "Evidence\uE200cite\uE202turn0search2\uE201"
        headers = { "Authorization" => "Bearer #{@token}" }

        post api_v1_conversation_messages_url(@chat),
          params: { content: content }, headers: headers, as: :json
        assert_response :created
        assert_equal content, @chat.messages.last.content
        assert_equal content, JSON.parse(response.body).dig("message", "content")

        multipart_content = "Multipart #{content}"
        post api_v1_conversation_messages_url(@chat),
          params: { content: multipart_content, files: [ fixture_file_upload("test_image.png", "image/png") ] },
          headers: headers
        assert_response :created
        assert_equal multipart_content, @chat.messages.last.content
        assert_equal multipart_content, JSON.parse(response.body).dig("message", "content")
        assert @chat.messages.last.attachments.attached?
      end

      test "rejects resident marker-only content after normalization" do
        headers = resident_headers
        assert_no_difference "Message.count" do
          post api_v1_conversation_messages_url(@chat),
            params: { content: " \uE200cite\uE202turn0search2\uE201\n" },
            headers: headers, as: :json
        end

        assert_response :unprocessable_entity
        assert_includes JSON.parse(response.body)["errors"], "Content or at least one file is required"
      end

      test "accepts marker-only resident content with an attachment" do
        post api_v1_conversation_messages_url(@chat),
          params: {
            content: "\uE200cite\uE202turn0search2\uE201",
            files: [ fixture_file_upload("test_image.png", "image/png") ]
          },
          headers: resident_headers

        assert_response :created
        assert_equal "", @chat.messages.last.content
        assert @chat.messages.last.attachments.attached?
      end

      test "agent-scoped key posts an image-only message" do
        agent = agents(:research_assistant)
        agent.update_columns(account_id: @account.id) # seat a resident hosted in this room's account
        agent_key = ApiKey.generate_for(@user, name: "Agent image postback", agent: agent)
        @chat.agents << agent
        @chat.update!(manual_responses: true)

        post api_v1_conversation_messages_url(@chat),
          params: { files: [ fixture_file_upload("test_image.png", "image/png") ] },
          headers: { "Authorization" => "Bearer #{agent_key.raw_token}" }

        assert_response :created
        message = @chat.messages.order(:created_at).last
        assert_nil message.content
        assert message.attachments.attached?
        assert message.completed?
      end

      test "rejects an empty agent message" do
        agent = agents(:research_assistant)
        agent.update_columns(account_id: @account.id) # seat a resident hosted in this room's account
        agent_key = ApiKey.generate_for(@user, name: "Agent empty postback", agent: agent)
        @chat.agents << agent

        assert_no_difference "Message.count" do
          post api_v1_conversation_messages_url(@chat),
            params: { content: "" },
            headers: { "Authorization" => "Bearer #{agent_key.raw_token}" }
        end

        assert_response :unprocessable_entity
        assert_includes JSON.parse(response.body)["errors"], "Content or at least one file is required"
      end

      test "accepts arbitrary agent attachment formats" do
        agent = agents(:research_assistant)
        agent.update_columns(account_id: @account.id) # seat a resident hosted in this room's account
        agent_key = ApiKey.generate_for(@user, name: "Agent invalid file postback", agent: agent)
        @chat.agents << agent

        assert_difference "Message.count" do
          post api_v1_conversation_messages_url(@chat),
            params: {
              content: "Store as a downloadable attachment",
              files: [ fixture_file_upload("test.exe", "application/x-msdownload") ]
            },
            headers: { "Authorization" => "Bearer #{agent_key.raw_token}" }
        end

        assert_response :created
        assert_equal "test.exe", Message.last.attachments.first.filename.to_s
      end

      test "agent-scoped key cannot post to conversation without agent" do
        agent = agents(:research_assistant)
        agent_key = ApiKey.generate_for(@user, name: "Agent postback", agent: agent)

        post api_v1_conversation_messages_url(@chat),
          params: { content: "External reply" },
          headers: { "Authorization" => "Bearer #{agent_key.raw_token}" }

        assert_response :not_found
      end

      test "rejects archived conversations" do
        @chat.archive!

        post api_v1_conversation_messages_url(@chat),
             params: { content: "New message" },
             headers: { "Authorization" => "Bearer #{@token}" }
        assert_response :unprocessable_entity

        json = JSON.parse(response.body)
        assert_equal "Conversation is archived or deleted", json["error"]
      end

      test "rejects discarded conversations" do
        @chat.discard!

        post api_v1_conversation_messages_url(@chat),
             params: { content: "New message" },
             headers: { "Authorization" => "Bearer #{@token}" }
        assert_response :unprocessable_entity
      end

      test "returns unauthorized without token" do
        post api_v1_conversation_messages_url(@chat),
             params: { content: "New message" }
        assert_response :unauthorized
      end

      test "returns 404 for other user's conversation" do
        other_user = users(:existing_user)
        other_account = other_user.personal_account
        other_chat = other_account.chats.create!(model_id: "openrouter/auto", title: "Other Chat")

        post api_v1_conversation_messages_url(other_chat),
             params: { content: "New message" },
             headers: { "Authorization" => "Bearer #{@token}" }
        assert_response :not_found
      end

      private

      def resident_headers
        agent = agents(:research_assistant)
        agent.update_columns(account_id: @account.id)
        @chat.agents << agent
        @chat.update!(manual_responses: true)
        key = ApiKey.generate_for(@user, name: "Citation postback", agent: agent)
        { "Authorization" => "Bearer #{key.raw_token}" }
      end

    end
  end
end
