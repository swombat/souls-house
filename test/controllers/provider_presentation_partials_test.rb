require "test_helper"

class ProviderPresentationPartialsTest < ActionDispatch::IntegrationTest

  setup do
    @account = accounts(:personal_account)
    @agent = agents(:research_assistant)
    @agent.update_columns(runtime: "external", model_id: "anthropic/claude-opus-4.6",
      telegram_bot_username: "synthetic_bot", telegram_bot_token: "synthetic-token")
    Setting.instance.update!(allow_agents: true)
    sign_in users(:user_1)
  end

  test "subscriber-only partial neither mints a link nor evaluates unrelated presentation" do
    cache_keys = []
    listener = ->(*args) { cache_keys << ActiveSupport::Notifications::Event.new(*args).payload[:key].to_s }
    ActiveSupport::Notifications.subscribed(listener, "cache_write.active_support") do
      Agents::ProviderSubscriptionPresentation.stub :call, ->(*) { flunk "count evaluated provider presenter" } do
        Agents::ModelCatalogue.stub :grouped, -> { flunk "count evaluated catalog" } do
          AgentInteractionCostReport.stub :new, ->(*) { flunk "count evaluated costs" } do
            get edit_account_agent_path(@account, @agent), headers: partial("agents/edit", "telegram_subscriber_count")
            assert_response :success
          end
        end
      end
    end
    assert_not cache_keys.any? { |key| key.include?("telegram_deep_link:") }
    assert_equal 0, response.parsed_body.dig("props", "telegram_subscriber_count")
    %w[telegram_deep_link interactions interactions_pagination cost_report grouped_models subagent_catalog provider_subscription].each do |key|
      assert_not response.parsed_body.fetch("props").key?(key)
    end
  end

  test "provider-only partial is a persisted read and never mints a telegram token" do
    original = @agent.reload.attributes
    keys = []
    listener = ->(*args) { keys << ActiveSupport::Notifications::Event.new(*args).payload[:key].to_s }
    ActiveSupport::Notifications.subscribed(listener, "cache_write.active_support") do
      Agents::Sandbox.stub :new, ->(*) { flunk "partial instantiated runtime auth" } do
        AgentInteractionCostReport.stub :new, ->(*) { flunk "provider partial evaluated costs" } do
          get edit_account_agent_path(@account, @agent),
            headers: partial("agents/edit", "provider_subscription,can_manage_provider_subscription")
          assert_response :success
        end
      end
    end
    assert_equal "anthropic", response.parsed_body.dig("props", "provider_subscription", "provider")
    assert_equal true, response.parsed_body.dig("props", "can_manage_provider_subscription")
    assert_not keys.any? { |key| key.include?("telegram_deep_link:") }
    assert_equal original, @agent.reload.attributes
  end

  test "service-connections-only partial reads actual chat counts without unrelated work or token writes" do
    connection = @account.service_connections.create!(
      provider: "telegram", connected_by_user: users(:user_1), management_scope: "personal",
      status: "connected", credential_kind: "session", credential_metadata: { credential_strategy: "connector" }
    )
    connection.comms_chats.create!(provider_chat_id: "synthetic", sync_state: { synced: nil })
    keys = []
    listener = ->(*args) { keys << ActiveSupport::Notifications::Event.new(*args).payload[:key].to_s }
    ActiveSupport::Notifications.subscribed(listener, "cache_write.active_support") do
      Agents::ProviderSubscriptionPresentation.stub :call, ->(*) { flunk "connections evaluated provider presenter" } do
        Agents::ModelCatalogue.stub :grouped, -> { flunk "connections evaluated model catalog" } do
          Agents::SubagentCatalog.stub :new, ->(*) { flunk "connections evaluated subagent catalog" } do
            AgentInteractionCostReport.stub :new, ->(*) { flunk "connections evaluated costs" } do
              Agents::Sandbox.stub :new, ->(*) { flunk "connections probed runtime" } do
                get edit_account_agent_path(@account, @agent), headers: partial("agents/edit", "service_connections")
                assert_response :success
              end
            end
          end
        end
      end
    end
    props = response.parsed_body.fetch("props")
    comms = props.fetch("service_connections").find { |value| value["id"] == connection.public_id }.fetch("comms")
    assert_equal 1, comms.fetch("chats")
    assert_equal 1, comms.fetch("synced_chats")
    assert_not keys.any? { |key| key.include?("telegram_deep_link:") }, "partial minted a registration token"
    %w[telegram_deep_link telegram_subscriber_count interactions interactions_pagination cost_report
       grouped_models subagent_catalog subagent_providers subagent_catalog_empty_reason provider_subscription].each do |key|
      assert_not props.key?(key), key
    end
  end

  test "account provider-list partial skips API key configuration presentation" do
    Agents::Sandbox.stub :new, ->(*) { flunk "account presentation instantiated runtime auth" } do
      get account_agent_api_keys_path(@account),
        headers: partial("accounts/agent_api_keys", "subscription_agents,can_manage_ai_credentials")
      assert_response :success
    end
    props = response.parsed_body.fetch("props")
    assert props.fetch("subscription_agents").any? { |value| value["id"] == @agent.to_param }
    assert_not props.key?("ai_api_keys_configured")
    assert_equal true, props["can_manage_ai_credentials"]
  end

  private

  def partial(component, props)
    {
      "X-Inertia" => "true", "X-Inertia-Version" => ViteRuby.digest,
      "X-Inertia-Partial-Component" => component, "X-Inertia-Partial-Data" => props
    }
  end

end
