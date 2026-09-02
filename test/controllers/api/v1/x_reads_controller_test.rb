require "test_helper"

module Api
  module V1
    class XReadsControllerTest < ActionDispatch::IntegrationTest

      setup do
        @user = users(:confirmed_user)
        @agent = agents(:research_assistant)
        @api_key = ApiKey.generate_for(@user, name: "Resident X", agent: @agent)
      end

      test "returns X content and remaining request and spend allowance" do
        reader = fake_reader(
          result: {
            operation: "search",
            model: "grok-test",
            content: "A current answer.",
            citations: [],
            usage: {
              cost_in_usd_ticks: 312_190_000,
              cost_usd: "0.031219"
            },
            provider_request_id: "resp_123"
          }
        )

        XReader.stub(:new, -> { reader }) do
          post_x_read(operation: "search", query: "What changed?")
        end

        assert_response :ok
        json = JSON.parse(response.body)
        assert_equal "A current answer.", json["content"]
        assert_equal 9, window(json, "agent_hour").dig("requests", "remaining")
        assert_equal "0.268781", window(json, "agent_hour").dig("spend", "remaining_usd")
        assert json.dig("rate_limits", "request_counted")

        event = MeteredActionEvent.find_by!(request_id: json["request_id"])
        assert_equal "completed", event.outcome
        assert_equal "resp_123", event.provider_request_id
        assert_equal 312_190_000, event.cost_in_usd_ticks
      end

      test "rejects user-scoped keys" do
        user_key = ApiKey.generate_for(@user, name: "User X")

        post api_v1_x_reads_url,
          params: { operation: "search", query: "Question" },
          headers: { "Authorization" => "Bearer #{user_key.raw_token}" },
          as: :json

        assert_response :forbidden
      end

      test "returns validation errors without consuming an attempt" do
        reader = Object.new
        reader.define_singleton_method(:prepare) do |**|
          raise XReader::InvalidRequest, "Invalid X handle"
        end

        assert_no_difference -> { MeteredActionEvent.count } do
          XReader.stub(:new, -> { reader }) do
            post_x_read(operation: "search", query: "Question", handles: [ "bad handle" ])
          end
        end

        assert_response :unprocessable_entity
        json = JSON.parse(response.body)
        assert_equal "Invalid X handle", json["error"]
        assert_equal 10, window(json, "agent_hour").dig("requests", "remaining")
        assert_not json.dig("rate_limits", "request_counted")
      end

      test "blocks requests after the resident hourly request limit" do
        10.times { create_event(created_at: 5.minutes.ago) }
        reader = fake_reader(result: nil)

        XReader.stub(:new, -> { reader }) do
          post_x_read(operation: "search", query: "Question")
        end

        assert_response :too_many_requests
        json = JSON.parse(response.body)
        assert_includes json.dig("rate_limits", "blocked_by"), "agent_hour.requests"
        assert_equal 0, window(json, "agent_hour").dig("requests", "remaining")
        assert response.headers["Retry-After"].to_i.positive?
      end

      test "blocks requests after the resident hourly spend cap" do
        create_event(created_at: 5.minutes.ago, outcome: "completed", cost_in_usd_ticks: 3_000_000_000)
        reader = fake_reader(result: nil)

        XReader.stub(:new, -> { reader }) do
          post_x_read(operation: "search", query: "Question")
        end

        assert_response :too_many_requests
        json = JSON.parse(response.body)
        assert_includes json.dig("rate_limits", "blocked_by"), "agent_hour.spend"
        assert_equal "0.0", window(json, "agent_hour").dig("spend", "remaining_usd")
      end

      test "counts an admitted attempt when xAI returns an error" do
        reader = fake_reader(error: XReader::UpstreamError.new(
          "No result",
          provider_request_id: "resp_failed",
          usage: { cost_in_usd_ticks: 20_000_000 },
          cost_in_usd_ticks: 20_000_000
        ))

        XReader.stub(:new, -> { reader }) do
          post_x_read(operation: "search", query: "Question")
        end

        assert_response :bad_gateway
        json = JSON.parse(response.body)
        assert_equal 9, window(json, "agent_hour").dig("requests", "remaining")
        assert json.dig("rate_limits", "request_counted")

        event = MeteredActionEvent.find_by!(request_id: json["request_id"])
        assert_equal "upstream_error", event.outcome
        assert_equal 20_000_000, event.cost_in_usd_ticks
      end

      private

      def fake_reader(result: nil, error: nil)
        Object.new.tap do |reader|
          reader.define_singleton_method(:prepare) { |**attributes| attributes }
          reader.define_singleton_method(:call) do |_prepared|
            raise error if error
            raise "reader should not have been called" unless result
            result
          end
        end
      end

      def post_x_read(**params)
        post api_v1_x_reads_url,
          params:,
          headers: { "Authorization" => "Bearer #{@api_key.raw_token}" },
          as: :json
      end

      def create_event(created_at:, outcome: "admitted", cost_in_usd_ticks: nil)
        MeteredActionEvent.create!(
          account: @agent.account,
          agent: @agent,
          action: "x_read",
          request_id: SecureRandom.uuid,
          outcome:,
          provider: "xai",
          cost_in_usd_ticks:,
          created_at:,
          updated_at: created_at
        )
      end

      def window(json, id)
        json.dig("rate_limits", "windows").find { |candidate| candidate["id"] == id }
      end

    end
  end
end
