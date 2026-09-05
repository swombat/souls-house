require "test_helper"

module Api
  module V1
    class AgentAnnouncesControllerTest < ActionDispatch::IntegrationTest

      setup do
        @agent = agents(:research_assistant)
        @agent.update!(
          uuid: SecureRandom.uuid_v7,
          runtime: "provisioning",
          trigger_bearer_token: "tr_valid"
        )
      end

      test "announce promotes agent to external with valid trigger token" do
        post api_v1_agent_announce_url(@agent.uuid),
          params: { endpoint_url: "https://agent.example.com" }.to_json,
          headers: {
            "Authorization" => "Bearer tr_valid",
            "Content-Type" => "application/json"
          }

        assert_response :success
        @agent.reload
        assert_equal "external", @agent.runtime
        assert_equal "healthy", @agent.health_state
        assert_equal "https://agent.example.com", @agent.endpoint_url
        assert_not_nil @agent.last_announced_at
      end

      test "deprecated and migrating residents cannot announce themselves back into availability" do
        %w[deprecated inline migrating].each do |runtime|
          @agent.update_columns(runtime: runtime)
          post api_v1_agent_announce_url(@agent.uuid),
            params: { endpoint_url: "https://agent.example.com" }.to_json,
            headers: { "Authorization" => "Bearer tr_valid", "Content-Type" => "application/json" }
          assert_response :conflict
          assert_equal runtime, @agent.reload.runtime
        end
      end

      test "announce rejects invalid trigger token" do
        post api_v1_agent_announce_url(@agent.uuid),
          params: { endpoint_url: "https://agent.example.com" }.to_json,
          headers: {
            "Authorization" => "Bearer nope",
            "Content-Type" => "application/json"
          }

        assert_response :unauthorized
        assert_equal "provisioning", @agent.reload.runtime
      end

    end
  end
end
