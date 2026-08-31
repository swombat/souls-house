require "test_helper"

module Api
  module V1
    class SubscriptionUsagesControllerTest < ActionDispatch::IntegrationTest

      setup do
        @user = users(:confirmed_user)
        @agent = agents(:research_assistant)
        @agent.update!(model_id: "openai/gpt-5")
        @api_key = ApiKey.generate_for(@user, name: "Resident usage", agent: @agent)
      end

      test "returns only the authenticated resident's subscription usage" do
        snapshot = {
          "provider" => "openai",
          "status" => "available",
          "windows" => [
            {
              "id" => "session",
              "label" => "Session",
              "remaining_percent" => 42,
              "resets_at" => "2026-09-07T03:35:00Z",
              "blocking" => true
            }
          ]
        }
        client = Object.new
        client.define_singleton_method(:usage) do |provider:, model:, refresh:|
          raise "wrong provider" unless provider == "openai"
          raise "wrong model" unless model == "gpt-5"
          raise "unexpected refresh" if refresh

          snapshot
        end

        AgentProviderAuthClient.stub(:new, client) do
          get api_v1_subscription_usage_url,
            headers: { "Authorization" => "Bearer #{@api_key.raw_token}" }
        end

        assert_response :ok
        json = JSON.parse(response.body)
        assert_equal "openai", json["provider"]
        assert_equal "gpt-5", json["model"]
        assert_equal @agent.provider_auth_mode("openai"), json["auth_mode"]
        assert_equal 42, json.dig("windows", 0, "remaining_percent")
      end

      test "rejects user-scoped keys" do
        user_key = ApiKey.generate_for(@user, name: "User usage")

        get api_v1_subscription_usage_url,
          headers: { "Authorization" => "Bearer #{user_key.raw_token}" }

        assert_response :forbidden
      end

      test "rejects requests without a key" do
        get api_v1_subscription_usage_url

        assert_response :unauthorized
      end

    end
  end
end
