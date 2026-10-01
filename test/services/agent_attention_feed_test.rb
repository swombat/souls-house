require "test_helper"

class AgentAttentionFeedTest < ActiveSupport::TestCase

  setup do
    @account = accounts(:personal_account)
    @agent = agents(:research_assistant)
    @other_agent = agents(:code_reviewer)
    @user = users(:user_1)
  end

  test "combines human, resident, and Telegram candidates with split counts" do
    human_chat = create_chat("Human latest", @agent)
    human_message = human_chat.messages.create!(role: "user", user: @user, content: "Human message", created_at: 3.hours.ago)

    resident_chat = create_chat("Resident latest", @agent, @other_agent)
    resident_message = resident_chat.messages.create!(
      role: "assistant", agent: @other_agent, content: "Resident message", created_at: 2.hours.ago
    )

    subscription = create_subscription
    telegram_message = subscription.telegram_messages.create!(
      role: "user", text: "Telegram message", sender_name: "Daniel", sent_at: 1.hour.ago
    )

    result = AgentAttentionFeed.new(@agent).call

    assert_equal({ helixkit: "ok", telegram: "ok" }, result[:checked])
    assert_equal 3, result.dig(:counts, :total)
    assert_equal 2, result.dig(:counts, :helixkit)
    assert_equal 1, result.dig(:counts, :telegram)
    assert_equal({ human: 2, resident: 1, unknown: 0 }, result.dig(:counts, :by_author_type))
    assert_equal [ telegram_message.to_param, resident_message.to_param, human_message.to_param ],
      result[:items].map { |item| item.dig(:latest_message, :id) }
  end

  test "omits conversations and Telegram threads after the agent holds the latest word" do
    chat = create_chat("Answered chat", @agent)
    chat.messages.create!(role: "user", user: @user, content: "Question", created_at: 2.hours.ago)
    chat.messages.create!(role: "assistant", agent: @agent, content: "Answer", created_at: 1.hour.ago)

    subscription = create_subscription
    subscription.telegram_messages.create!(role: "user", text: "Question", sent_at: 2.hours.ago)
    subscription.telegram_messages.create!(role: "assistant", text: "Answer", sent_at: 1.hour.ago)

    result = AgentAttentionFeed.new(@agent).call

    assert_empty result[:items]
    assert_equal 0, result.dig(:counts, :total)
  end

  test "ignores tool rows and excludes archived discarded and other-agent conversations" do
    included = create_chat("Included", @agent)
    human = included.messages.create!(role: "user", user: @user, content: "Visible", created_at: 2.hours.ago)
    included.messages.create!(role: "tool", content: "Tool result", created_at: 1.hour.ago)

    archived = create_chat("Archived", @agent)
    archived.messages.create!(role: "user", user: @user, content: "Archived message")
    archived.archive!

    discarded = create_chat("Discarded", @agent)
    discarded.messages.create!(role: "user", user: @user, content: "Discarded message")
    discarded.discard!

    other = create_chat("Other agent", @other_agent)
    other.messages.create!(role: "user", user: @user, content: "Not yours")
    other_subscription = @other_agent.telegram_subscriptions.create!(
      user: users(:existing_user),
      telegram_chat_id: SecureRandom.random_number(1_000_000)
    )
    other_subscription.telegram_messages.create!(role: "user", text: "Also not yours", sent_at: Time.current)

    result = AgentAttentionFeed.new(@agent).call

    assert_equal [ human.to_param ], result[:items].map { |item| item.dig(:latest_message, :id) }
  end

  test "keeps old and blocked Telegram candidates visible as unreachable" do
    subscription = create_subscription
    message = subscription.telegram_messages.create!(
      role: "user", text: "Old but still present", sender_name: "Daniel", sent_at: 2.years.ago
    )
    subscription.mark_blocked!

    item = AgentAttentionFeed.new(@agent).call[:items].sole

    assert_equal message.to_param, item.dig(:latest_message, :id)
    assert_equal false, item[:reachable]
  end

  test "does not expose a subscriber email when no profile name exists" do
    @user.profile.update_columns(first_name: nil, last_name: nil)
    subscription = create_subscription
    subscription.telegram_messages.create!(role: "user", text: "Hello", sent_at: Time.current)

    item = AgentAttentionFeed.new(@agent).call[:items].sole

    assert_equal @user.email_address.split("@").first, item[:title]
    assert_equal @user.email_address.split("@").first, item.dig(:latest_message, :author_name)
    assert_not_includes item[:title], "@"
    assert_not_includes item.dig(:latest_message, :author_name), "@"
  end

  test "uses unknown authorship and previews only message content" do
    chat = create_chat("Legacy", @agent)
    message = chat.messages.create!(
      role: "assistant",
      content: "Visible content",
      thinking: "SECRET THINKING",
      tools_used: [ "SECRET TOOL" ]
    )

    item = AgentAttentionFeed.new(@agent).call[:items].sole

    assert_equal "unknown", item.dig(:latest_message, :author_type)
    assert_equal "Visible content", item.dig(:latest_message, :preview)
    assert_not_includes item.dig(:latest_message, :preview), message.thinking
    assert_not_includes item.dig(:latest_message, :preview), message.tools_used.first
  end

  test "uses an attachment placeholder when the latest message has no text" do
    chat = create_chat("Attachment", @agent)
    message = chat.messages.create!(role: "user", user: @user, content: "", skip_content_validation: true)
    message.attachments.attach(
      io: File.open(Rails.root.join("test/fixtures/files/test.txt")),
      filename: "test.txt",
      content_type: "text/plain"
    )

    item = AgentAttentionFeed.new(@agent).call[:items].sole

    assert_equal "[attachment]", item.dig(:latest_message, :preview)
  end

  test "preserves one channel when the other fails" do
    chat = create_chat("Still visible", @agent)
    chat.messages.create!(role: "user", user: @user, content: "Visible")
    feed = AgentAttentionFeed.new(@agent)

    result = feed.stub(:telegram_items, -> { raise "Telegram failed" }) { feed.call }

    assert_equal({ helixkit: "ok", telegram: "failed" }, result[:checked])
    assert_equal 1, result.dig(:counts, :total)
    assert_equal "helixkit", result.dig(:items, 0, :channel)
  end

  test "preserves Telegram items when souls.house collection fails" do
    subscription = create_subscription
    subscription.telegram_messages.create!(role: "user", text: "Still visible", sent_at: Time.current)
    feed = AgentAttentionFeed.new(@agent)

    result = feed.stub(:helixkit_items, -> { raise "souls.house failed" }) { feed.call }

    assert_equal({ helixkit: "failed", telegram: "ok" }, result[:checked])
    assert_equal 1, result.dig(:counts, :total)
    assert_equal "telegram", result.dig(:items, 0, :channel)
  end

  private

  def create_chat(title, *agents)
    chat = Chat.new(
      account: @account,
      title: title,
      manual_responses: true,
      model_id_string: "openrouter/auto"
    )
    chat.agents.concat(agents)
    chat.save!
    chat
  end

  def create_subscription
    @agent.telegram_subscriptions.create!(
      user: @user,
      telegram_chat_id: SecureRandom.random_number(1_000_000)
    )
  end

end
