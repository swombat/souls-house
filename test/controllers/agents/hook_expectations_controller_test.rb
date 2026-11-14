require "test_helper"

class Agents::HookExpectationsControllerTest < ActionDispatch::IntegrationTest

  setup do
    @account = accounts(:team_account)
    @agent = agents(:other_account_agent)
    Setting.instance.update!(allow_agents: true)
  end

  test "the owner sees the events and nothing set yet" do
    sign_in(users(:user_1))
    get account_agent_hook_expectations_path(@account, @agent), as: :json

    assert_response :success
    body = response.parsed_body
    assert_equal HookPresence::EVENTS, body["events"]
    assert_equal({}, body["hook_expectations"])
  end

  test "the owner turns an event off, recorded as the owner's and audited" do
    sign_in(users(:user_1))
    patch account_agent_hook_expectations_path(@account, @agent),
      params: { event: "session_start", state: "off" }, as: :json

    assert_response :success
    entry = @agent.reload.hook_expectations["session_start"]
    assert_equal "off", entry["state"]
    assert_equal "owner", entry["source"]
    assert_equal "off", response.parsed_body.dig("hook_expectations", "session_start", "state")
    audit = AuditLog.where(action: "update_resident_hook_expectation", auditable: @agent).last
    assert_equal "session_start", audit.data["event"]
  end

  test "an unknown event or state is refused" do
    sign_in(users(:user_1))
    patch account_agent_hook_expectations_path(@account, @agent), params: { event: "whenever", state: "off" }, as: :json
    assert_response :unprocessable_entity
    patch account_agent_hook_expectations_path(@account, @agent), params: { event: "stop", state: "maybe" }, as: :json
    assert_response :unprocessable_entity
    assert_equal({}, @agent.reload.hook_expectations)
  end

  test "a member who isn't the owner can't see or change it" do
    member = @account.users.where.not(id: users(:user_1).id).first
    skip "fixture account has no other member" unless member
    sign_in(member)
    patch account_agent_hook_expectations_path(@account, @agent), params: { event: "stop", state: "off" }, as: :json
    assert_not_equal 200, response.status
    assert_equal({}, @agent.reload.hook_expectations)
  end

end
