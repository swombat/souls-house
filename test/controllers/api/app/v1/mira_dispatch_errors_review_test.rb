require_relative "write_api_test"

class Api::App::V1::WriteApiTest
  test "review accepted retry still succeeds when recovery enqueue is unavailable" do
    send_message("review-key-001", "Hey @Grok, review recovery")
    assert_response :created
    travel 31.seconds do
      MessageDispatchJob.stub(:perform_later, ->(*) { raise "queue unavailable" }) do
        send_message("review-key-001", "Hey @Grok, review recovery")
      end
      assert_response :ok
      assert_equal "pending", response.parsed_body.dig("dispatch", "status")
    end
  end
end
