require "test_helper"
require "webmock/minitest"

# #596: a group wake names the speaker and says they are not the owner.
class ExternalAgentTelegramGroupRequestTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:research_assistant)
    @agent.update!(runtime: "external", endpoint_url: "https://agent.example.com", trigger_bearer_token: "tr_valid")
    @group = @agent.telegram_groups.create!(telegram_chat_id: -100_7, title: "MGL")
    @group.allow!(by: users(:user_1))
    @message = @group.telegram_messages.create!(
      role: "user", text: "@test_bot can you check the contract?", sender_name: "Ana Ruiz",
      sender_username: "ana_r", sender_telegram_user_id: 77, telegram_message_id: 41,
      reply_to_telegram_message_id: 40, sent_at: Time.current
    )
  end

  test "the group wake names the speaker, the group, and the limits of their standing" do
    body = nil
    stub_request(:post, "https://agent.example.com/trigger")
      .with { |request| body = JSON.parse(request.body); true }
      .to_return(status: 200, body: { status: "ok" }.to_json)

    result = ExternalAgentTelegramRequest.new(agent: @agent, subscription: @group, telegram_message: @message).call

    assert_equal 200, result[:status]
    assert_equal "group", body["chat_kind"]
    assert_equal "Ana Ruiz", body.dig("sender", "name")
    assert_equal "MGL", body.dig("sender", "group")
    request = body["request"]
    assert_includes request, "Telegram group your owner has allowed"
    assert_includes request, "from Ana Ruiz (@ana_r)"
    assert_includes request, "not from your owner"
    assert_includes request, "no authority"
    assert_includes request, "soulshouse-send-telegram --reply-to #{@group.to_param}"
    assert_equal "Telegram group MGL", @agent.agent_runtime_interactions.last.requested_by
    assert_equal 40, body["messages"].first["reply_to_telegram_message_id"]
  end

end
