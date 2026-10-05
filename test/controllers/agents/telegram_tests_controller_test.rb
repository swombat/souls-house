require "test_helper"

class Agents::TelegramTestsControllerTest < ActionDispatch::IntegrationTest

  setup do
    @user = users(:user_1)
    @account = accounts(:personal_account)
    @agent = agents(:research_assistant)

    Setting.instance.update!(allow_agents: true)

    post login_path, params: {
      email_address: @user.email_address,
      password: "password123"
    }
    assert_redirected_to root_path
  end

  test "create redirects with error when telegram not configured" do
    post account_agent_telegram_test_path(@account, @agent)

    assert_redirected_to edit_account_agent_path(@account, @agent)
    assert_match(/not configured/, flash[:alert])
  end

  test "create redirects with error when no subscribers" do
    configure_telegram_agent!

    post account_agent_telegram_test_path(@account, @agent)

    assert_redirected_to edit_account_agent_path(@account, @agent)
    assert_match(/No users have connected/, flash[:alert])
  end

  test "create sends to subscribers and redirects with success" do
    configure_telegram_agent!
    @agent.telegram_subscriptions.create!(user: @user, telegram_chat_id: telegram_test_chat_id)

    VCR.use_cassette("controllers/agents/telegram_tests/send_test_notification_success") do
      post account_agent_telegram_test_path(@account, @agent)
    end

    assert_redirected_to edit_account_agent_path(@account, @agent)
    assert_match(/Test message sent to 1 subscriber/, flash[:notice])
  end

  test "create handles telegram API error" do
    configure_telegram_agent!
    @agent.telegram_subscriptions.create!(user: @user, telegram_chat_id: telegram_test_chat_id)

    VCR.use_cassette("controllers/agents/telegram_tests/send_test_notification_error", match_requests_on: [ :method, :uri ]) do
      post account_agent_telegram_test_path(@account, @agent)
    end

    assert_redirected_to edit_account_agent_path(@account, @agent)
    assert_match(/Telegram error/, flash[:alert])
  end

  test "requires authentication" do
    delete logout_path

    post account_agent_telegram_test_path(@account, @agent)
    assert_response :redirect
  end

  test "scopes to current account" do
    other_agent = agents(:other_account_agent)

    post account_agent_telegram_test_path(@account, other_agent)
    assert_response :not_found
  end

  private

  def configure_telegram_agent!
    @agent.update!(
      telegram_bot_token: telegram_test_bot_token,
      telegram_bot_username: telegram_test_bot_username
    )
  end

  def telegram_test_bot_token
    ENV.fetch("TELEGRAM_TEST_BOT_TOKEN", "telegram-test-bot-token")
  end

  def telegram_test_bot_username
    ENV.fetch("TELEGRAM_TEST_BOT_USERNAME", "test_bot")
  end

  def telegram_test_chat_id
    ENV.fetch("TELEGRAM_TEST_CHAT_ID", "12345").to_i
  end

end
