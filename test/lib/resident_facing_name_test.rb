require "test_helper"
require "webmock/minitest"

# Residents are shown people by profile name, never by email address: in
# transcript lines, conversation metadata, mid-run messages and requester
# provenance. A person's own words stay verbatim, addresses included.
class ResidentFacingNameTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:research_assistant)
    @ada = person("ada.lovelace.private@example.test", "Ada", "Lovelace")
    @chat = @agent.account.chats.create!(title: "Names", manual_responses: true, agents: [ @agent ])
  end

  test "a named person is their profile name" do
    assert_equal "Ada Lovelace", ResidentFacingName.for(@ada)
  end

  test "a person with no profile name is a member id, not their email or its local part" do
    nameless = person("nameless.private@example.test", nil, nil)

    label = ResidentFacingName.for(nameless)
    assert_equal "Member #{nameless.obfuscated_id}", label
    refute_includes label, "nameless"
  end

  test "transcript lines and metadata name people, not their addresses" do
    nameless = person("nameless.private@example.test", nil, nil)
    @chat.messages.create!(user: @ada, role: "user", content: "Write to me at ada.lovelace.private@example.test")
    @chat.messages.create!(user: nameless, role: "user", content: "Me too.")

    request = ExternalAgentResponseRequest.new(agent: @agent, chat: @chat)
    lines = @chat.messages.order(:id).map { |message| request.send(:format_transcript_line, message) }
    metadata = request.send(:conversation_metadata)

    assert lines.first.start_with?("Ada Lovelace [")
    assert lines.second.start_with?("Member #{nameless.obfuscated_id} [")
    assert_includes metadata, "humans_seen_in_transcript: Ada Lovelace, Member #{nameless.obfuscated_id}"
    refute_includes metadata, "@example.test"
    refute_includes lines.second, "nameless"
    # What she typed is hers and stays as she wrote it.
    assert_includes lines.first, "Write to me at ada.lovelace.private@example.test"
  end

  test "namesakes are told apart by id, consistently, and only when names collide" do
    other_ada = person("ada.second.private@example.test", "Ada", "Lovelace")
    grace = person("grace.private@example.test", "Grace", "Hopper")
    [ @ada, other_ada, grace ].each { |user| @chat.messages.create!(user:, role: "user", content: "Hello from #{user.id}") }

    request = ExternalAgentResponseRequest.new(agent: @agent, chat: @chat)
    lines = @chat.messages.order(:id).map { |message| request.send(:format_transcript_line, message) }
    metadata = request.send(:conversation_metadata)

    first = "Ada Lovelace [#{@ada.obfuscated_id}]"
    second = "Ada Lovelace [#{other_ada.obfuscated_id}]"
    assert lines[0].start_with?("#{first} [")
    assert lines[1].start_with?("#{second} [")
    assert lines[2].start_with?("Grace Hopper [")
    [ first, second, "Grace Hopper" ].each { |label| assert_includes metadata, label }
    refute_includes metadata, "Grace Hopper ["
    refute_includes metadata, "@example.test"
  end

  test "mid-run messages use the same labels as the transcript" do
    other_ada = person("ada.second.private@example.test", "Ada", "Lovelace")
    seen = @chat.messages.create!(user: @ada, role: "user", content: "First.")
    run = AgentRuntimeInteraction.reserve!(agent: @agent, chat: @chat)
    run.update!(last_included_message_id: seen.id)
    @chat.messages.create!(user: other_ada, role: "user", content: "Second.")
    @chat.messages.create!(user: @ada, role: "user", content: "Third.")

    authors = run.messages_since_transcript.map { |message| message[:author] }
    assert_equal [ "Ada Lovelace [#{other_ada.obfuscated_id}]", "Ada Lovelace [#{@ada.obfuscated_id}]" ], authors
    authors.each { |author| refute_includes author, "@" }
  end

  test "wake provenance names the person, not their address" do
    message = @chat.messages.create!(user: @ada, role: "user", content: "Anyone?")
    handoff = MessageHandoff.new(message:)

    assert_equal "Ada Lovelace", handoff.send(:requester_label)
  end

  test "Telegram provenance carries the subscriber's name and no account email" do
    @agent.update!(runtime: "external", endpoint_url: "https://agent.example.com", trigger_bearer_token: "tr_valid", persistent_session: true)
    subscription = @agent.telegram_subscriptions.create!(user: @ada, telegram_chat_id: 222, telegram_username: "ada_l")
    message = subscription.telegram_messages.create!(role: "user", text: "Hello", sender_name: "Ada",
      sender_username: "ada_l", telegram_message_id: 1, sent_at: Time.current)
    body = nil
    stub_request(:post, "https://agent.example.com/trigger")
      .with { |request| body = JSON.parse(request.body) }
      .to_return(status: 200, body: { status: "ok", chaos_session_id: "s" }.to_json)

    ExternalAgentTelegramRequest.new(agent: @agent, subscription:, telegram_message: message).call

    assert_equal "Ada Lovelace", body["requested_by"]
    assert_equal({ "name" => "Ada Lovelace", "telegram_username" => "ada_l" }, body["sender"])
    assert_includes body["request"], "Sender: Ada Lovelace\n"
    refute_includes body["request"], "ada.lovelace.private@example.test"
    assert_equal "Ada Lovelace", @agent.agent_runtime_interactions.last.requested_by
  end

  test "an unnamed Telegram subscriber is a member id in full and delta prompts; typed addresses stay" do
    nameless = person("nameless.telegram.private@example.test", nil, nil)
    subscription = @agent.telegram_subscriptions.create!(user: nameless, telegram_chat_id: 333, telegram_username: "nm")
    message = subscription.telegram_messages.create!(role: "user", text: "Reply to typed.address@example.test",
      sender_name: "NM", sender_username: "nm", telegram_message_id: 1, sent_at: Time.current)
    request = ExternalAgentTelegramRequest.new(agent: @agent, subscription:, telegram_message: message)
    label = "Member #{nameless.obfuscated_id}"

    full = request.send(:request_text)
    delta = request.send(:request_delta_text)

    assert_includes full, "Sender: #{label}\n"
    assert_includes delta, "New Telegram DMs from #{label} "
    [ full, delta ].each do |prompt|
      refute_includes prompt, "nameless.telegram.private"
      assert_includes prompt, "typed.address@example.test"
    end
  end

  private

  def person(email, first, last)
    User.create!(email_address: email).tap { |user| user.profile.update!(first_name: first, last_name: last) }
  end

end
