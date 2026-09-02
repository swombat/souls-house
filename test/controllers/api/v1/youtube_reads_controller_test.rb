require "test_helper"

module Api
  module V1
    class YoutubeReadsControllerTest < ActionDispatch::IntegrationTest

      setup do
        @user = users(:confirmed_user)
        @agent = agents(:research_assistant)
        @api_key = ApiKey.generate_for(@user, name: "Resident YouTube", agent: @agent)
      end

      test "returns video content for the authenticated resident" do
        reader = Object.new
        reader.define_singleton_method(:call) do |url:, operation:, question:|
          raise "wrong URL" unless url == "https://youtu.be/56Vy6cGfXXY"
          raise "wrong operation" unless operation == "ask"
          raise "wrong question" unless question == "What is the conclusion?"

          {
            video_url: "https://www.youtube.com/watch?v=56Vy6cGfXXY",
            operation: "ask",
            model: "gemini-test",
            generated_transcript: false,
            content: "Pause before reacting.",
            usage: { total_tokens: 100 }
          }
        end

        YoutubeVideoReader.stub(:new, -> { reader }) do
          post api_v1_youtube_reads_url,
            params: {
              url: "https://youtu.be/56Vy6cGfXXY",
              operation: "ask",
              question: "What is the conclusion?"
            },
            headers: { "Authorization" => "Bearer #{@api_key.raw_token}" },
            as: :json
        end

        assert_response :ok
        json = JSON.parse(response.body)
        assert_equal "Pause before reacting.", json["content"]
        assert_equal "gemini-test", json["model"]
      end

      test "rejects user-scoped keys" do
        user_key = ApiKey.generate_for(@user, name: "User YouTube")

        post api_v1_youtube_reads_url,
          params: { url: "https://youtu.be/56Vy6cGfXXY", operation: "transcript" },
          headers: { "Authorization" => "Bearer #{user_key.raw_token}" },
          as: :json

        assert_response :forbidden
      end

      test "returns validation errors without calling upstream" do
        reader = Object.new
        reader.define_singleton_method(:call) do |**|
          raise YoutubeVideoReader::InvalidRequest, "URL must identify one public YouTube video"
        end

        YoutubeVideoReader.stub(:new, -> { reader }) do
          post api_v1_youtube_reads_url,
            params: { url: "https://example.com", operation: "transcript" },
            headers: { "Authorization" => "Bearer #{@api_key.raw_token}" },
            as: :json
        end

        assert_response :unprocessable_entity
        assert_equal "URL must identify one public YouTube video", JSON.parse(response.body)["error"]
      end

    end
  end
end
