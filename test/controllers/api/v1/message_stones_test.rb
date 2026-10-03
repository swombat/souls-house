require "test_helper"

module Api
  module V1
    class MessageStonesTest < ActionDispatch::IntegrationTest

      setup do
        @user = users(:confirmed_user)
        @agent = agents(:research_assistant)
        @chat = @agent.account.chats.create!(title: "Reference room", model_id: "openrouter/auto", agents: [ @agent ])
        @stone = Stone.publish!(chat: @chat, title: "Shared stone", html: "<!doctype html><html><body><p>Shared</p></body></html>", author: @agent, public: true)
        @revision = @stone.latest_revision
        key = ApiKey.generate_for(@user, name: "References", agent: @agent)
        @headers = { "Authorization" => "Bearer #{key.raw_token}" }
        @path = api_v1_conversation_messages_url(@chat)
      end

      test "posting attaches a same conversation revision and returns its pinned public card" do
        assert_difference [ "Message.count", "MessageStoneRevision.count" ], 1 do
          post @path, params: { content: "Here is the stone", stone_revision_ids: [ @revision.to_param, @revision.to_param ] }, headers: @headers, as: :json
        end
        assert_response :created
        card = response.parsed_body.dig("message", "stones_json").sole
        assert_equal @revision.to_param, card["id"]
        assert_equal "/stones/#{@stone.public_token}/revisions/1", card["url"]
        assert_equal [ @revision ], @chat.messages.last.stone_revisions.to_a
      end

      test "cross conversation and withdrawn references do not persist a message" do
        other = @agent.account.chats.create!(title: "Another room", model_id: "openrouter/auto", agents: [ @agent ])
        assert_no_difference [ "Message.count", "MessageStoneRevision.count" ] do
          post api_v1_conversation_messages_url(other), params: { content: "Wrong room", stone_revision_ids: [ @revision.to_param ] }, headers: @headers, as: :json
        end
        assert_response :not_found
        @stone.withdraw!
        assert_no_difference [ "Message.count", "MessageStoneRevision.count" ] do
          post @path, params: { content: "Withdrawn", stone_revision_ids: [ @revision.to_param ] }, headers: @headers, as: :json
        end
        assert_response :not_found
      end

    end
  end
end
