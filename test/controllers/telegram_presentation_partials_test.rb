require "test_helper"

class TelegramPresentationPartialsTest < ActionDispatch::IntegrationTest

  setup do
    @account = accounts(:personal_account)
    @agent = agents(:research_assistant)
    @agent.update_columns(telegram_bot_username: "synthetic_bot", telegram_bot_token: "synthetic-token")
    Setting.instance.update!(allow_agents: true)
    sign_in users(:user_1)
  end

  test "configuration and count partials never mint registration tokens or evaluate provider and costs" do
    keys = []
    listener = ->(*args) { keys << ActiveSupport::Notifications::Event.new(*args).payload[:key].to_s }
    ActiveSupport::Notifications.subscribed(listener, "cache_write.active_support") do
      Agents::ProviderSubscriptionPresentation.stub :call, ->(*) { flunk "Telegram partial evaluated provider" } do
        AgentInteractionCostReport.stub :new, ->(*) { flunk "Telegram partial evaluated costs" } do
          get edit_account_agent_path(@account, @agent), headers: partial("telegram_configuration,telegram_subscriber_count")
          assert_response :success
        end
      end
    end
    assert_equal({ "configured" => true, "username" => "synthetic_bot" }, response.parsed_body.dig("props", "telegram_configuration"))
    assert_equal 0, response.parsed_body.dig("props", "telegram_subscriber_count")
    assert_not response.parsed_body.fetch("props").key?("telegram_deep_link")
    assert_not keys.any? { |key| key.include?("telegram_deep_link:") }
  end

  test "link is optional on full visits and minted only by explicit partial reveal" do
    keys = []
    listener = ->(*args) { keys << ActiveSupport::Notifications::Event.new(*args).payload[:key].to_s }
    ActiveSupport::Notifications.subscribed(listener, "cache_write.active_support") do
      get edit_account_agent_path(@account, @agent), headers: { "X-Inertia" => "true", "X-Inertia-Version" => ViteRuby.digest }
      assert_response :success
      assert_not response.parsed_body.fetch("props").key?("telegram_deep_link")
      assert_not keys.any? { |key| key.include?("telegram_deep_link:") }
      get edit_account_agent_path(@account, @agent), headers: partial("telegram_deep_link")
      assert_response :success
      assert_match %r{\Ahttps://t.me/synthetic_bot\?start=[A-Za-z0-9]+\z}, response.parsed_body.dig("props", "telegram_deep_link")
      assert_equal 1, keys.count { |key| key.include?("telegram_deep_link:") }
    end
  end

  test "explicit reveals stay scoped to the current account and require authentication" do
    keys = []
    listener = ->(*args) { keys << ActiveSupport::Notifications::Event.new(*args).payload[:key].to_s }
    ActiveSupport::Notifications.subscribed(listener, "cache_write.active_support") do
      get edit_account_agent_path(@account, agents(:other_account_agent)), headers: partial("telegram_deep_link")
      assert_response :not_found
      delete logout_path
      get edit_account_agent_path(@account, @agent), headers: partial("telegram_deep_link")
      assert_response :redirect
    end
    assert_not keys.any? { |key| key.include?("telegram_deep_link:") }
  end

  test "explicit reveal clears an unconfigured bot without minting a token" do
    @agent.update_columns(telegram_bot_token: nil)
    @agent.stub :telegram_deep_link_for, ->(*) { flunk "unconfigured bot minted a link" } do
      get edit_account_agent_path(@account, @agent), headers: partial("telegram_deep_link")
      assert_response :success
      assert_nil response.parsed_body.dig("props", "telegram_deep_link")
    end
  end

  private

  def partial(props)
    {
      "X-Inertia" => "true", "X-Inertia-Version" => ViteRuby.digest,
      "X-Inertia-Partial-Component" => "agents/edit", "X-Inertia-Partial-Data" => props
    }
  end

end
