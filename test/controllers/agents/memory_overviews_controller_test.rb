require "test_helper"

class Agents::MemoryOverviewsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @account = accounts(:personal_account)
    @agent = agents(:research_assistant)
    Setting.instance.update!(allow_agents: true)
  end

  test "account members receive summary without private history" do
    login(users(:user_1))
    service = Struct.new(:call).new({ journals: { count: 2 }, node_count: 3, edge_count: 4, days: [] })
    Agents::MemoryOverview.stub(:new, ->(agent) { assert_equal @agent, agent; service }) do
      get account_agent_memory_overview_path(@account, @agent), as: :json
    end
    assert_response :success
    assert_equal 2, response.parsed_body.dig("journals", "count")
    assert_includes response.headers["Cache-Control"], "no-store"
    Agents::MemoryHistory.stub(:new, ->(*) { flunk "Must authorize before reading private memory" }) do
      get history_account_agent_memory_overview_path(@account, @agent), as: :json
    end
    assert_response :forbidden
  end

  test "site admins can read contents and filter with all off" do
    login(users(:site_admin_user))
    calls = []
    service = Object.new
    service.define_singleton_method(:call) do |**args|
      calls << args
      { items: [ { body: "Private journal" } ], next_cursor: nil }
    end
    Agents::MemoryHistory.stub(:new, ->(*) { service }) do
      get history_account_agent_memory_overview_path(@account, @agent), as: :json
      assert_response :success
      assert_equal "Private journal", response.parsed_body["items"].first["body"]
      assert_equal Agents::MemoryHistory::KINDS, calls.last[:kinds]
      get history_account_agent_memory_overview_path(@account, @agent), params: { kinds: "" }, as: :json
      assert_response :success
      assert_empty calls.last[:kinds]
    end
  end

  test "members cannot access residents belonging to a different account" do
    login(users(:user_1))
    Agents::MemoryOverview.stub(:new, ->(*) { flunk "Cross-account read" }) do
      get account_agent_memory_overview_path(@account, agents(:other_account_agent)), as: :json
    end
    assert_response :not_found
  end

  test "invalid history cursor is a client error" do
    login(users(:site_admin_user))
    get history_account_agent_memory_overview_path(@account, @agent), params: { cursor: "bad" }, as: :json
    assert_response :bad_request
    get history_account_agent_memory_overview_path(@account, @agent), params: { cursor: [ "bad" ] }, as: :json
    assert_response :bad_request
  end

  private

  def login(user)
    post login_path, params: { email_address: user.email_address, password: "password123" }
    assert_redirected_to root_path
  end
end
