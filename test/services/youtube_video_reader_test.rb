require "test_helper"

class YoutubeVideoReaderTest < ActiveSupport::TestCase

  test "normalizes supported YouTube URL forms" do
    expected = "https://www.youtube.com/watch?v=56Vy6cGfXXY"

    assert_equal expected, YoutubeVideoReader.normalize_url("https://youtu.be/56Vy6cGfXXY?t=30")
    assert_equal expected, YoutubeVideoReader.normalize_url("https://www.youtube.com/watch?v=56Vy6cGfXXY&list=other")
    assert_equal expected, YoutubeVideoReader.normalize_url("https://youtube.com/shorts/56Vy6cGfXXY")
    assert_equal expected, YoutubeVideoReader.normalize_url("https://www.youtube.com/embed/56Vy6cGfXXY")
  end

  test "rejects non-YouTube and ambiguous URLs" do
    assert_raises(YoutubeVideoReader::InvalidRequest) do
      YoutubeVideoReader.normalize_url("https://example.com/watch?v=56Vy6cGfXXY")
    end
    assert_raises(YoutubeVideoReader::InvalidRequest) do
      YoutubeVideoReader.normalize_url("http://www.youtube.com/watch?v=56Vy6cGfXXY")
    end
    assert_raises(YoutubeVideoReader::InvalidRequest) do
      YoutubeVideoReader.normalize_url("https://www.youtube.com/playlist?list=example")
    end
  end

  test "asks Gemini about the normalized video and returns usage" do
    transport = lambda do |uri, payload|
      assert_equal YoutubeVideoReader::ENDPOINT, uri
      assert_equal "gemini-test", payload[:model]
      assert_equal "https://www.youtube.com/watch?v=56Vy6cGfXXY", payload.dig(:input, 1, :uri)
      assert_includes payload.dig(:input, 0, :text), "What is the practical conclusion?"

      success_response(
        text: "The practical conclusion is to pause before reacting. [19:22]",
        usage: {
          "total_input_tokens" => 112_000,
          "total_output_tokens" => 20,
          "total_tokens" => 112_020,
          "input_tokens_by_modality" => [ { "modality" => "video", "tokens" => 111_900 } ]
        }
      )
    end

    result = YoutubeVideoReader.new(
      api_key: "test-key",
      model: "gemini-test",
      transport:
    ).call(
      url: "https://youtu.be/56Vy6cGfXXY",
      operation: "ask",
      question: "What is the practical conclusion?"
    )

    assert_equal "ask", result[:operation]
    assert_not result[:generated_transcript]
    assert_includes result[:content], "pause before reacting"
    assert_equal 111_900, result.dig(:usage, :video_tokens)
  end

  test "marks transcripts as generated" do
    reader = YoutubeVideoReader.new(
      api_key: "test-key",
      transport: ->(*) { success_response(text: "[00:00] Opening words.") }
    )

    result = reader.call(
      url: "https://www.youtube.com/watch?v=56Vy6cGfXXY",
      operation: "transcript"
    )

    assert result[:generated_transcript]
    assert_equal "[00:00] Opening words.", result[:content]
  end

  test "requires a question for ask" do
    reader = YoutubeVideoReader.new(api_key: "test-key", transport: ->(*) { flunk })

    error = assert_raises(YoutubeVideoReader::InvalidRequest) do
      reader.call(url: "https://youtu.be/56Vy6cGfXXY", operation: "ask")
    end
    assert_equal "A question is required for the ask operation", error.message
  end

  test "raises UpstreamError when Gemini wraps the error in a JSON array" do
    reader = YoutubeVideoReader.new(
      api_key: "test-key",
      transport: ->(*) {
        http_response(
          [
            {
              "error" => {
                "code" => 400,
                "message" => "API key not valid. Please pass a valid API key.",
                "status" => "INVALID_ARGUMENT"
              }
            }
          ],
          success: false
        )
      }
    )

    error = assert_raises(YoutubeVideoReader::UpstreamError) do
      reader.call(
        url: "https://youtu.be/jNQXAC9IVRw",
        operation: "ask",
        question: "In one sentence, what happens?"
      )
    end
    assert_equal "API key not valid. Please pass a valid API key.", error.message
  end

  test "raises UpstreamError for a Gemini object error without exploding" do
    reader = YoutubeVideoReader.new(
      api_key: "test-key",
      transport: ->(*) {
        http_response(
          {
            "error" => { "message" => "Gemini could not read this video" },
            "status" => "failed"
          },
          success: false
        )
      }
    )

    error = assert_raises(YoutubeVideoReader::UpstreamError) do
      reader.call(url: "https://youtu.be/jNQXAC9IVRw", operation: "transcript")
    end
    assert_equal "Gemini could not read this video", error.message
  end

  private

  def success_response(text:, usage: {})
    http_response({
      "status" => "completed",
      "model" => "gemini-test",
      "usage" => usage,
      "steps" => [
        {
          "type" => "model_output",
          "content" => [ { "type" => "text", "text" => text } ]
        }
      ]
    }, success: true)
  end

  def http_response(body, success:)
    Struct.new(:body, :success) do
      def is_a?(klass)
        (success && klass == Net::HTTPSuccess) || super
      end
    end.new(body.is_a?(String) ? body : body.to_json, success)
  end

end
