require "test_helper"

class XReaderTest < ActiveSupport::TestCase

  test "searches X once with normalized filters and returns exact cost metadata" do
    transport = lambda do |uri, payload|
      assert_equal XReader::ENDPOINT, uri
      assert_equal "grok-test", payload[:model]
      assert_equal 1, payload[:max_turns]
      assert_equal 1, payload[:tools].length
      assert_equal "x_search", payload.dig(:tools, 0, :type)
      assert_equal %w[example another], payload.dig(:tools, 0, :allowed_x_handles)
      assert_equal "2026-09-01", payload.dig(:tools, 0, :from_date)
      assert_equal "2026-09-02", payload.dig(:tools, 0, :to_date)
      assert_includes payload[:input], "What changed?"
      assert_includes payload[:input], "Use no more than one X search call"

      success_response
    end
    reader = XReader.new(api_key: "test-key", model: "grok-test", transport:)
    prepared = reader.prepare(
      operation: "search",
      query: "What changed?",
      handles: [ "@example", "another", "example" ],
      from_date: "2026-09-01",
      to_date: "2026-09-02"
    )

    result = reader.call(prepared)

    assert_equal "search", result[:operation]
    assert_equal "A concise answer.", result[:content]
    assert_equal "https://x.com/example/status/123", result.dig(:citations, 0, :url)
    assert_equal 312_190_000, result.dig(:usage, :cost_in_usd_ticks)
    assert_equal "0.031219", result.dig(:usage, :cost_usd)
    assert_equal 1, result.dig(:usage, :server_side_tool_usage_details, "x_search_calls")
  end

  test "normalizes a Twitter post URL before reading its thread" do
    transport = lambda do |_, payload|
      assert_includes payload[:input], "https://x.com/i/status/1234567890"
      assert_includes payload[:input], "What is the evidence?"
      success_response
    end
    reader = XReader.new(api_key: "test-key", transport:)
    prepared = reader.prepare(
      operation: "thread",
      url: "https://twitter.com/example/status/1234567890?ref=home",
      question: "What is the evidence?"
    )

    assert_equal "https://x.com/i/status/1234567890", prepared.url
    assert_equal "thread", reader.call(prepared)[:operation]
  end

  test "rejects invalid requests before calling xAI" do
    reader = XReader.new(api_key: "test-key", transport: ->(*) { flunk })

    assert_raises(XReader::InvalidRequest) do
      reader.prepare(operation: "thread", url: "https://example.com/status/123")
    end
    assert_raises(XReader::InvalidRequest) do
      reader.prepare(operation: "search", query: "Question", handles: [ "bad handle" ])
    end
    assert_raises(XReader::InvalidRequest) do
      reader.prepare(
        operation: "search",
        query: "Question",
        from_date: "2026-09-02",
        to_date: "2026-09-01"
      )
    end
  end

  test "preserves request and cost metadata on upstream errors" do
    reader = XReader.new(
      api_key: "test-key",
      transport: ->(*) { response({ status: "failed", id: "resp_failed", usage: { cost_in_usd_ticks: 20_000_000 }, error: { message: "No result" } }) }
    )
    prepared = reader.prepare(operation: "search", query: "Question")

    error = assert_raises(XReader::UpstreamError) { reader.call(prepared) }

    assert_equal "No result", error.message
    assert_equal "resp_failed", error.provider_request_id
    assert_equal 20_000_000, error.cost_in_usd_ticks
  end

  private

  def success_response
    response(
      {
        status: "completed",
        id: "resp_123",
        model: "grok-test",
        usage: {
          input_tokens: 100,
          output_tokens: 20,
          total_tokens: 120,
          num_server_side_tools_used: 1,
          server_side_tool_usage_details: { x_search_calls: 1 },
          cost_in_usd_ticks: 312_190_000
        },
        output: [
          {
            type: "message",
            content: [
              {
                type: "output_text",
                text: "A concise answer.",
                annotations: [
                  {
                    type: "url_citation",
                    url: "https://x.com/example/status/123",
                    title: "Example post",
                    start_index: 0,
                    end_index: 7
                  }
                ]
              }
            ]
          }
        ]
      }
    )
  end

  def response(payload)
    Struct.new(:body) do
      def is_a?(klass)
        klass == Net::HTTPSuccess || super
      end
    end.new(payload.to_json)
  end

end
