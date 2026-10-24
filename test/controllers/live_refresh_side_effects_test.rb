require "test_helper"

class LiveRefreshSideEffectsTest < ActionDispatch::IntegrationTest

  setup do
    @account = accounts(:personal_account)
    @agent = agents(:research_assistant)
    @agent.update_columns(runtime: "external")
    Setting.instance.update!(allow_agents: true)
    sign_in users(:user_1)
  end

  test "agent health integration provider and navbar partials never inspect portability" do
    [
      "agent,memories,interactions,interactions_pagination,cost_report",
      "service_connections",
      "provider_subscription,can_manage_provider_subscription",
      "accounts,expired_subscriptions", "room_activity",
      "reply_attention,accounts,expired_subscriptions", "rooms,current_room"
    ].each do |props|
      Agents::Portability::Transport.stub :new, ->(*) { flunk "unrequested portability inspected for #{props}" } do
        get edit_account_agent_path(@account, @agent), headers: partial("agents/edit", props)
        assert_response :success
        assert_not response.parsed_body.fetch("props").key?("portability")
      end
    end
  end

  test "explicit portability partial still evaluates its authorized presentation" do
    Agents::Portability::Export.stub :unavailable_reason, nil do
      transport = Object.new
      calls = 0
      transport.define_singleton_method(:stopped!) { calls += 1 }
      Agents::Portability::Transport.stub :new, transport do
        get edit_account_agent_path(@account, @agent), headers: partial("agents/edit", "portability")
        assert_response :success
        assert_equal true, response.parsed_body.dig("props", "portability", "can_manage")
        assert_equal 1, calls
        assert_not response.parsed_body.fetch("props").key?("agent")
      end
    end
  end

  test "github navbar partials never fetch repository list but requested repos do" do
    @account.create_github_integration!(access_token: "synthetic-token", github_username: "synthetic")
    original = GithubIntegration.instance_method(:fetch_repos)
    GithubIntegration.define_method(:fetch_repos) { raise "unrequested GitHub fetch" }
    [
      "accounts,expired_subscriptions", "room_activity",
      "reply_attention,accounts,expired_subscriptions", "rooms,current_room"
    ].each do |props|
      get select_repo_github_integration_path, headers: partial("settings/github_select_repo", props)
      assert_response :success
      assert_not response.parsed_body.fetch("props").key?("repos")
    end
    calls = 0
    GithubIntegration.define_method(:fetch_repos) do
      calls += 1
      [ { "full_name" => "synthetic/repo", "private" => true } ]
    end
    get select_repo_github_integration_path, headers: partial("settings/github_select_repo", "repos")
    assert_response :success
    assert_equal [ { "full_name" => "synthetic/repo", "private" => true } ], response.parsed_body.dig("props", "repos")
    assert_equal 1, calls
  ensure
    GithubIntegration.define_method(:fetch_repos, original) if original
  end

  private

  def partial(component, props)
    {
      "X-Inertia" => "true", "X-Inertia-Version" => ViteRuby.digest,
      "X-Inertia-Partial-Component" => component, "X-Inertia-Partial-Data" => props
    }
  end

end
