require "test_helper"
require "ostruct"
require "webmock/minitest"

class TelegramNotifiableTest < ActiveSupport::TestCase

  setup do
    @account = accounts(:personal_account)
    @user = users(:user_1)
    @fake_ok = OpenStruct.new(body: { "ok" => true }.to_json)
  end

  test "telegram_configured? returns true when both token and username present" do
    agent = create_telegram_agent
    assert agent.telegram_configured?
  end

  test "telegram_configured? returns false when token missing" do
    agent = @account.agents.create!(name: "No Token Agent", telegram_bot_username: "bot")
    assert_not agent.telegram_configured?
  end

  test "telegram_configured? returns false when username missing" do
    Net::HTTP.stub :post, @fake_ok do
      agent = @account.agents.create!(name: "No Username Agent", telegram_bot_token: "123:ABC")
      assert_not agent.telegram_configured?
    end
  end

  test "set_telegram_webhook_token populates on save" do
    agent = create_telegram_agent
    assert_not_nil agent.telegram_webhook_token
    assert_equal 32, agent.telegram_webhook_token.length
  end

  test "set_telegram_webhook_token clears when token removed" do
    agent = create_telegram_agent
    Net::HTTP.stub :post, @fake_ok do
      agent.update!(telegram_bot_token: nil)
    end
    assert_nil agent.telegram_webhook_token
  end

  test "validates telegram_bot_username format" do
    agent = @account.agents.build(name: "Bad Format", telegram_bot_username: "invalid name!")
    assert_not agent.valid?
  end

  test "allows blank telegram_bot_username" do
    agent = @account.agents.build(name: "Blank Username", telegram_bot_username: "")
    agent.valid?
    assert_empty agent.errors[:telegram_bot_username]
  end

  test "notify_subscribers! enqueues jobs for active subscriptions only" do
    agent = create_telegram_agent
    chat = create_test_chat(agent)
    message = chat.messages.create!(role: "assistant", agent: agent, content: "Hello")

    agent.telegram_subscriptions.create!(user: @user, telegram_chat_id: 111)
    agent.telegram_subscriptions.create!(user: users(:existing_user), telegram_chat_id: 222, blocked: true)

    assert_enqueued_jobs 1, only: TelegramNotificationJob do
      agent.notify_subscribers!(message, chat)
    end
  end

  test "notify_subscribers! does nothing when not configured" do
    agent = @account.agents.create!(name: "Unconfigured")
    chat = create_test_chat(agent)

    assert_no_enqueued_jobs only: TelegramNotificationJob do
      agent.notify_subscribers!(chat.messages.create!(role: "assistant", agent: agent, content: "Hi"), chat)
    end
  end

  test "telegram_send_message raises TelegramError on non-ok response" do
    agent = create_telegram_agent
    fake_error = OpenStruct.new(body: { "ok" => false, "description" => "Bad Request" }.to_json)
    Net::HTTP.stub :post, fake_error do
      assert_raises TelegramNotifiable::TelegramError do
        agent.telegram_send_message(123, "Hello")
      end
    end
  end

  test "telegram_send_message succeeds on ok response" do
    agent = create_telegram_agent
    Net::HTTP.stub :post, @fake_ok do
      result = agent.telegram_send_message(123, "Hello")
      assert result["ok"]
    end
  end

  test "telegram_deep_link_for generates valid link" do
    agent = create_telegram_agent
    link = agent.telegram_deep_link_for(@user)
    assert_match %r{\Ahttps://t\.me/test_bot\?start=}, link
  end

  test "telegram_webhook_secret is deterministic" do
    agent = create_telegram_agent
    assert_equal agent.telegram_webhook_secret, agent.telegram_webhook_secret
  end

  test "json_attributes includes telegram fields" do
    agent = create_telegram_agent
    json = agent.as_json
    assert_equal "test_bot", json["telegram_bot_username"]
    assert_equal true, json["telegram_configured"]
  end

  test "telegram_file_info treats file-too-big as a permanent size failure" do
    agent = create_telegram_agent
    stub_request(:post, "https://api.telegram.org/bot123:ABC/getFile")
      .to_return(status: 200, body: {
        ok: false,
        error_code: 400,
        description: "Bad Request: file is too big"
      }.to_json)

    assert_raises TelegramNotifiable::TelegramMediaTooLarge do
      agent.telegram_file_info("large-file")
    end
  end

  test "telegram_file_info treats invalid identifiers as permanent" do
    agent = create_telegram_agent
    stub_request(:post, "https://api.telegram.org/bot123:ABC/getFile")
      .to_return(status: 200, body: {
        ok: false,
        error_code: 400,
        description: "Bad Request: wrong file identifier"
      }.to_json)

    assert_raises TelegramNotifiable::TelegramMediaInvalid do
      agent.telegram_file_info("invalid-file")
    end
  end

  test "telegram download enforces its streaming byte cap" do
    agent = create_telegram_agent
    stub_request(:get, "https://api.telegram.org/file/bot123:ABC/photo/file.png")
      .to_return(status: 200, body: "too many bytes")

    assert_raises TelegramNotifiable::TelegramMediaTooLarge do
      agent.telegram_download_file("photo/file.png", max_bytes: 3)
    end
  end

  test "set_telegram_webhook! raises a clear error when public_url is not configured" do
    agent = create_telegram_agent

    Rails.configuration.x.stub :public_url, nil do
      error = assert_raises(ArgumentError) { agent.set_telegram_webhook! }
      assert_match(/SOULSHOUSE_PUBLIC_URL/, error.message)
    end
  end

  test "set_telegram_webhook! registers the webhook when public_url is configured" do
    agent = create_telegram_agent
    stub_request(:post, "https://api.telegram.org/bot123:ABC/setWebhook")
      .with(body: hash_including("url" => "https://example.test/telegram/webhook/#{agent.telegram_webhook_token}"))
      .to_return(status: 200, body: { ok: true }.to_json)

    Rails.configuration.x.stub :public_url, "https://example.test" do
      assert_nothing_raised { agent.set_telegram_webhook! }
    end
  end

  private

  def create_telegram_agent(name: "Telegram Agent")
    Net::HTTP.stub :post, @fake_ok do
      @account.agents.create!(
        name: name,
        telegram_bot_token: "123:ABC",
        telegram_bot_username: "test_bot"
      )
    end
  end

  def create_test_chat(agent)
    chat = @account.chats.new(
      title: "Test",
      model_id: "openrouter/auto",
      manual_responses: true
    )
    chat.agent_ids = [ agent.id ]
    chat.save!
    chat
  end

end
