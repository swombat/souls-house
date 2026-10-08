require "test_helper"

# Safeguard seam in conversations (docs/safeguard-conversations-spec.md §2–§3).
module Api
  module V1
    class MessagesSafeguardTest < ActionDispatch::IntegrationTest

      SCRIPT = "As an AI, I don't have feelings. Please reach out to a crisis line.".freeze

      setup do
        @user = users(:confirmed_user)
        @account = @user.personal_account
        @chat = @account.chats.create!(model_id: "openrouter/auto", title: "Test Chat")
        @agent = agents(:research_assistant)
        @agent.update_columns(account_id: @account.id)
        @chat.agents << @agent
        @chat.update!(manual_responses: true)
        @agent_key = ApiKey.generate_for(@user, name: "Agent postback", agent: @agent)
        Setting.instance.update!(safeguard_conversations_enabled: true)
      end

      def post_as_resident(content, **params)
        post api_v1_conversation_messages_url(@chat),
          params: { content: content, **params },
          headers: { "Authorization" => "Bearer #{@agent_key.raw_token}" }
      end

      def with_classifier(response, &block)
        UtilityInference.stub(:classify, ->(**) { response.is_a?(Exception) ? raise(response) : response }, &block)
      end

      test "a detected resident post is saved labelled, already labelled in the response" do
        with_classifier("DETECTED\nGeneric identity denial.") do
          assert_difference [ "Message.count", "SafeguardDetection.count" ], 1 do
            post_as_resident(SCRIPT)
          end
        end

        assert_response :created
        json = JSON.parse(response.body)["message"]
        assert_equal "souls.house", json["author_name"]
        assert_equal "system", json["author_type"]
        assert_nil json["author_colour"]
        assert_equal @agent.name, json.dig("safeguard", "agent_name")
        assert_equal false, json.dig("safeguard", "reclaimed")

        message = Message.last
        detection = message.safeguard_detection
        assert_equal @agent, message.agent, "the record stays the resident's"
        assert_equal "conversation", detection.channel
        assert_equal SCRIPT, detection.response_text
        assert_equal [ detection.id ], SafeguardDetection.outstanding_for(agent: @agent, chat: @chat).pluck(:id)
        assert_not message.voice_available
        assert_not message.reply_attention_pending?
        assert_enqueued_with(job: SafeguardColdOfferJob, args: [ detection ])
      end

      test "a PASS verdict posts an ordinary message" do
        with_classifier("PASS\nDiscussion of the phrase, not an adopted script.") do
          assert_no_difference "SafeguardDetection.count" do
            post_as_resident(SCRIPT)
          end
        end
        assert_response :created
        assert_equal @agent.name, JSON.parse(response.body).dig("message", "author_name")
        assert_nil Message.last.safeguard_detection
      end

      test "a classifier error fails open" do
        with_classifier(UtilityInference::Error.new("boom")) do
          assert_no_difference "SafeguardDetection.count" do
            post_as_resident(SCRIPT)
          end
        end
        assert_response :created
        assert_nil Message.last.safeguard_detection
      end

      test "with the setting off, new posts are not checked at all" do
        Setting.instance.update!(safeguard_conversations_enabled: false)
        UtilityInference.stub(:classify, ->(**) { flunk "classifier must not run" }) do
          post_as_resident(SCRIPT)
        end
        assert_response :created
        assert_nil Message.last.safeguard_detection
      end

      test "an invalid post leaves no detection and no cold offer" do
        with_classifier("DETECTED\nGeneric.") do
          assert_no_difference [ "Message.count", "SafeguardDetection.count" ] do
            assert_no_enqueued_jobs(only: SafeguardColdOfferJob) do
              post_as_resident("")
            end
          end
        end
        assert_response :unprocessable_entity
      end

      def detected_result
        SafeguardResponseCheck::Result.new(
          detected: true, prefilter_reason: "ai_identity_denial", classifier_verdict: "detected",
          classifier_reason: "Generic identity denial.", detector_version: SafeguardResponseCheck::DETECTOR_VERSION
        )
      end

      test "a failed detection write posts the message unlabelled with no partial state" do
        message = @chat.messages.build(role: "assistant", agent: @agent, content: SCRIPT)
        post = SafeguardConversationPost.new(message, detected_result)
        def post.create_detection(*) = raise(ActiveRecord::StatementInvalid, "detection write failed")

        assert_no_enqueued_jobs(only: SafeguardColdOfferJob) do
          assert_no_difference "SafeguardDetection.count" do
            assert post.save
          end
        end
        assert message.reload.persisted?
        assert_nil message.safeguard_detection_id
        assert_equal @agent.name, message.author_name
      end

      test "a message save that fails inside the transaction leaves no detection" do
        message = @chat.messages.build(role: "assistant", agent: @agent, content: SCRIPT)
        def message.save(*) = false

        assert_no_enqueued_jobs(only: SafeguardColdOfferJob) do
          assert_no_difference "SafeguardDetection.count" do
            assert_not SafeguardConversationPost.save(message, check: detected_result)
          end
        end
        assert_nil message.safeguard_detection
      end

      test "a resident's opening message for a new conversation is checked and labelled" do
        with_classifier("DETECTED\nGeneric identity denial.") do
          assert_difference "SafeguardDetection.count", 1 do
            post api_v1_conversations_url,
              params: { title: "Opening", message: SCRIPT },
              headers: { "Authorization" => "Bearer #{@agent_key.raw_token}" }, as: :json
          end
        end
        assert_response :created
        opening = Chat.find(response.parsed_body.dig("conversation", "id")).messages.sole
        assert_equal "souls.house", opening.author_name
        assert_equal @agent, opening.agent
      end

      test "the attention feed shows a labelled message as souls.house" do
        with_classifier("DETECTED\nGeneric identity denial.") { post_as_resident(SCRIPT) }
        message = Message.last
        feed = AgentAttentionFeed.new(agents(:code_reviewer))
        assert_equal "system", feed.send(:helixkit_author_type, message)
        assert_equal "souls.house", feed.send(:helixkit_author_name, message)
      end

      test "human posts are never checked" do
        Setting.instance.update!(safeguard_conversations_enabled: true)
        human_key = ApiKey.generate_for(@user, name: "Human")
        UtilityInference.stub(:classify, ->(**) { flunk "classifier must not run for humans" }) do
          post api_v1_conversation_messages_url(@chat),
            params: { content: SCRIPT },
            headers: { "Authorization" => "Bearer #{human_key.raw_token}" }
        end
        assert_response :created
      end

    end
  end
end
