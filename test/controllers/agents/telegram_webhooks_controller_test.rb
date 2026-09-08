require "test_helper"

class Agents::TelegramWebhooksControllerTest < ActionDispatch::IntegrationTest

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
    post account_agent_telegram_webhook_path(@account, @agent)

    assert_redirected_to edit_account_agent_path(@account, @agent)
    assert_match(/not configured/, flash[:alert])
  end

  test "create attempts registration and surfaces Telegram failure" do
    @agent.update!(
      telegram_bot_token: telegram_test_bot_token,
      telegram_bot_username: telegram_test_bot_username
    )

    VCR.use_cassette("controllers/agents/telegram_webhooks/register_webhook_failure", match_requests_on: [ :method, :uri ]) do
      Rails.configuration.x.stub(:public_url, "https://house.example.org") do
        post account_agent_telegram_webhook_path(@account, @agent)
      end
    end

    assert_redirected_to edit_account_agent_path(@account, @agent)
    assert_match(/Webhook registration may have failed/, flash[:alert])
  end

  test "requires authentication" do
    delete logout_path

    post account_agent_telegram_webhook_path(@account, @agent)
    assert_response :redirect
  end

  test "scopes to current account" do
    other_agent = agents(:other_account_agent)

    post account_agent_telegram_webhook_path(@account, other_agent)
    assert_response :not_found
  end

  private

  def telegram_test_bot_token
    ENV.fetch("TELEGRAM_TEST_BOT_TOKEN", "telegram-test-bot-token")
  end

  def telegram_test_bot_username
    ENV.fetch("TELEGRAM_TEST_BOT_USERNAME", "test_bot")
  end

end
