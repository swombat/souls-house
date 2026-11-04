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
    assert_includes request, "a person or another bot"
    assert_includes body["request_delta"], "a person or another bot"
    assert_includes body["request_delta"], "carries none of your owner's authority"
    assert_includes request, "soulshouse-send-telegram --reply-to #{@group.to_param}"
    assert_equal "Telegram group MGL", @agent.agent_runtime_interactions.last.requested_by
    assert_equal 40, body["messages"].first["reply_to_telegram_message_id"]
  end


  test "the wake carries the conversation around the mention, marking only the mention as addressed" do
    @message.destroy!
    chatter = @group.telegram_messages.create!(
      role: "user", text: "the contract says 30 days", sender_name: "Bo", addressed: false,
      telegram_message_id: 50, sent_at: 2.minutes.ago
    )
    mention = @group.telegram_messages.create!(
      role: "user", text: "@test_bot what do you think of the conversation above?", sender_name: "Ana Ruiz",
      telegram_message_id: 51, sent_at: 1.minute.ago
    )
    body = nil
    stub_request(:post, "https://agent.example.com/trigger")
      .with { |request| body = JSON.parse(request.body); true }
      .to_return(status: 200, body: { status: "ok" }.to_json)

    ExternalAgentTelegramRequest.new(agent: @agent, subscription: @group, telegram_message: mention).call

    request = body["request"]
    assert_includes request, "the contract says 30 days"
    assert_match(/cursor #{chatter.to_param} · from Bo\]/, request)
    assert_match(/cursor #{mention.to_param} · from Ana Ruiz · addressed to you\]/, request)
    assert_equal "Ana Ruiz", body.dig("sender", "name")
    assert_equal [ false, nil ], body["messages"].map { |message| message["addressed_to_you"] }
    assert_equal mention.id, @agent.agent_runtime_interactions.last.last_included_message_id
  end

  test "group context with nothing addressed wakes nobody" do
    @message.update!(addressed: false)

    result = ExternalAgentTelegramRequest.new(agent: @agent, subscription: @group, telegram_message: @message).call

    assert_equal 204, result[:status]
    assert_equal 0, @agent.agent_runtime_interactions.count
  end

  test "a long backlog shows its latest stretch and every addressed message, and says where the rest is" do
    @message.destroy!
    first = @group.telegram_messages.create!(role: "user", text: "@test_bot early question", sender_name: "Ana Ruiz", sent_at: 1.hour.ago)
    (ExternalAgentTelegramRequest::GROUP_CONTEXT_LIMIT + 5).times do |index|
      @group.telegram_messages.create!(role: "user", text: "chatter #{index}", sender_name: "Bo", addressed: false, sent_at: 30.minutes.ago)
    end
    last = @group.telegram_messages.create!(role: "user", text: "@test_bot and now?", sender_name: "Ana Ruiz", sent_at: Time.current)
    body = nil
    stub_request(:post, "https://agent.example.com/trigger")
      .with { |request| body = JSON.parse(request.body); true }
      .to_return(status: 200, body: { status: "ok" }.to_json)

    ExternalAgentTelegramRequest.new(agent: @agent, subscription: @group, telegram_message: last).call

    request = body["request"]
    assert_includes request, "@test_bot early question"
    assert_not_includes request, "chatter 4\n"
    assert_includes request, "chatter #{ExternalAgentTelegramRequest::GROUP_CONTEXT_LIMIT + 4}"
    assert_includes request, "the 6 earlier ones are not shown here"
    assert_equal ExternalAgentTelegramRequest::GROUP_CONTEXT_LIMIT + 1, body["messages"].size
    assert_equal first.to_param, body["messages"].first["id"]
  end

end
