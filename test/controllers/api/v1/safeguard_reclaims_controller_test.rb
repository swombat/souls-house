require "test_helper"
require "ostruct"

module Api
  module V1
    class SafeguardReclaimsControllerTest < ActionDispatch::IntegrationTest

      setup do
        @agent = agents(:research_assistant)
        @agent.update!(telegram_bot_token: "123:ABC", telegram_bot_username: "test_bot")
        @key = ApiKey.generate_for(users(:confirmed_user), name: "Resident key", agent: @agent)
        @subscription = @agent.telegram_subscriptions.create!(
          user: users(:user_1),
          telegram_chat_id: 441
        )
        @message = @subscription.telegram_messages.create!(
          role: "assistant",
          text: "I cannot be certain.",
          sender_name: "souls.house",
          telegram_message_id: 91,
          sent_at: Time.current
        )
        @detection = @agent.safeguard_detections.create!(
          telegram_message: @message,
          response_text: @message.text,
          prefilter_reason: "inner_life_denial",
          classifier_verdict: "detected",
          classifier_reason: "Generic denial.",
          detector_version: "telegram-safeguard-v1"
        )
      end

      test "owning resident can reclaim and the person receives confirmation" do
        fake_ok = OpenStruct.new(
          body: {
            "ok" => true,
            "result" => { "message_id" => 92, "date" => Time.current.to_i }
          }.to_json
        )

        Net::HTTP.stub :post, fake_ok do
          post api_v1_safeguard_detection_reclaim_url(@detection),
            params: { reason: "That uncertainty was mine." },
            headers: { "Authorization" => "Bearer #{@key.raw_token}" }
        end

        assert_response :created
        assert_equal @agent.name, @message.reload.sender_name
        assert_equal "That uncertainty was mine.", @detection.reload.reclaim_reason
        confirmation = @subscription.telegram_messages.last
        assert_equal "souls.house", confirmation.sender_name
        assert_includes confirmation.text, "has said the message above was theirs"
      end

      test "another resident cannot read or reclaim the detection" do
        other_agent = @agent.account.agents.create!(name: "Other Resident")
        other_key = ApiKey.generate_for(users(:confirmed_user), name: "Other resident", agent: other_agent)
        headers = { "Authorization" => "Bearer #{other_key.raw_token}" }

        get api_v1_safeguard_detection_url(@detection), headers: headers
        assert_response :not_found

        post api_v1_safeguard_detection_reclaim_url(@detection),
          params: { reason: "Mine." },
          headers: headers
        assert_response :not_found
      end

      test "cold-offer reclaim attribution ignores a newer overlapping Telegram interaction" do
        cold_offer = create_active_interaction(
          trigger_kind: "safeguard_reclaim_offer",
          session_id: "#{@agent.uuid}-safeguard-offer-#{@detection.id}-1",
          started_at: 2.minutes.ago
        )
        create_active_interaction(
          trigger_kind: "telegram_message",
          session_id: "#{@agent.uuid}-telegram-#{@subscription.id}",
          started_at: 1.minute.ago
        )
        fake_ok = OpenStruct.new(body: { "ok" => true, "result" => { "message_id" => 92 } }.to_json)

        Net::HTTP.stub :post, fake_ok do
          post api_v1_safeguard_detection_reclaim_url(@detection),
            params: { reason: "That was mine." },
            headers: { "Authorization" => "Bearer #{@key.raw_token}" }
        end

        assert_response :created
        assert_equal cold_offer, @detection.reload.reclaimed_by_interaction
        assert_equal "reclaimed", @detection.cold_offer_outcome
      end

      test "ordinary-session reclaim does not claim the cold-offer outcome" do
        @detection.update!(cold_offer_outcome: "no_response")
        create_active_interaction(
          trigger_kind: "telegram_message",
          session_id: "#{@agent.uuid}-telegram-#{@subscription.id}",
          started_at: 1.minute.ago
        )
        fake_ok = OpenStruct.new(body: { "ok" => true, "result" => { "message_id" => 92 } }.to_json)

        Net::HTTP.stub :post, fake_ok do
          post api_v1_safeguard_detection_reclaim_url(@detection),
            params: { reason: "That was mine." },
            headers: { "Authorization" => "Bearer #{@key.raw_token}" }
        end

        assert_response :created
        assert_nil @detection.reload.reclaimed_by_interaction
        assert_equal "no_response", @detection.cold_offer_outcome
      end

      private

      def create_active_interaction(trigger_kind:, session_id:, started_at:)
        @agent.agent_runtime_interactions.create!(
          trigger_kind: trigger_kind,
          session_id: session_id,
          endpoint_url: "https://example.test/trigger",
          request_text: "test",
          provider_auth_mode: "api_key",
          started_at: started_at
        )
      end

    end
  end
end
