require_relative "send_concurrency_test"

class Api::App::V1::SendConcurrencyTest
  test "review moderation enqueue failure after commit must not claim nothing was saved" do
    path = "/api/app/v1/conversations/#{@chat.to_param}/messages"
    ModerateMessageJob.stub(:perform_later, ->(*) { raise "moderation queue unavailable" }) do
      post path, params: { client_message_id: "review-commit-001", content: "Hey @Grok, committed" }, headers: bearer(@tokens)
    end
    assert_equal 1, @chat.messages.count
    assert_equal 1, MessageDispatch.where(chat: @chat).count
    assert_equal 1, AuditLog.where(action: "create_message", auditable: @chat.messages.sole).count
    assert_response :created
  end
end
