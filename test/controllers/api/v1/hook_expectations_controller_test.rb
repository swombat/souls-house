require "test_helper"

module Api
  module V1
    class HookExpectationsControllerTest < ActionDispatch::IntegrationTest

      setup do
        @user = users(:confirmed_user)
        @agent = agents(:research_assistant)
        @agent.update!(hook_expectations: {})
        @headers = auth(ApiKey.generate_for(@user, name: "Hooks", agent: @agent))
      end

      test "a resident marks a removal deliberate and reads its expectations back" do
        patch api_v1_agent_hook_expectations_url, params: { event: "stop", state: "off" }, headers: @headers, as: :json
        assert_response :ok
        assert_equal "no-store", response.headers["Cache-Control"]
        assert_equal "off", response.parsed_body.dig("hook_expectations", "stop", "state")
        assert_equal "resident", @agent.reload.hook_expectations.dig("stop", "source")

        get api_v1_agent_hook_expectations_url, headers: @headers
        assert_response :ok
        assert_equal %w[session_start before_turn stop], response.parsed_body["events"]
      end

      test "an unknown event is refused" do
        patch api_v1_agent_hook_expectations_url, params: { event: "pre_compact", state: "off" }, headers: @headers, as: :json
        assert_response :unprocessable_entity
      end

      test "a key without a resident is refused" do
        headers = auth(ApiKey.generate_for(@user, name: "Plain"))
        get api_v1_agent_hook_expectations_url, headers: headers
        assert_response :forbidden
      end

      private

      def auth(key)
        { "Authorization" => "Bearer #{key.raw_token}" }
      end

    end
  end
end
