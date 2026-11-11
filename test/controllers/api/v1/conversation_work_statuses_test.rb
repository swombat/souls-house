require "test_helper"

class Api::V1::ConversationWorkStatusesTest < ActionDispatch::IntegrationTest

  setup do
    @user = users(:user_1)
    @agent = agents(:research_assistant)
    @chat = @agent.account.chats.create!(title: "Work", model_id: "openrouter/auto", agents: [ @agent ], manual_responses: true)
    @headers = { "Authorization" => "Bearer #{ApiKey.generate_for(@user, name: "Work", agent: @agent).raw_token}" }
  end

  test "resident writes and gets conflicts with the current structured status" do
    update_status(state: "blocked", reason: "Need access", expected_revision: 0)
    assert_response :ok
    assert_equal "blocked", response.parsed_body.dig("work_status", "state")
    assert_equal 1, response.parsed_body.dig("work_status", "revision")
    log = AuditLog.where(action: "update_work_status", auditable: @chat).sole
    assert_nil log.user_id
    assert_equal @agent.id, log.data["agent_id"]
    assert response.parsed_body["updated_at"]
    since = response.parsed_body.dig("work_status", "since")
    update_status(state: "blocked", reason: "Need access", expected_revision: 1)
    assert_response :ok
    assert_equal since, response.parsed_body.dig("work_status", "since")
    assert_equal 1, response.parsed_body.dig("work_status", "revision")
    assert_equal 1, AuditLog.where(action: "update_work_status", auditable: @chat).count
    update_status(state: "idle", expected_revision: 0)
    assert_response :conflict
    assert_equal "blocked", response.parsed_body.dig("work_status", "state")
    update_status(state: nil, reason: nil, expected_revision: 1)
    assert_response :ok
    assert_nil response.parsed_body.dig("work_status", "state")
  end

  test "malformed input is 422 without coercion or persistence" do
    [
      {}, { state: "working" }, { state: "working", expected_revision: "0" },
      { state: "working", expected_revision: 0.0 }, { state: "working", expected_revision: false },
      { state: "working", expected_revision: -1 }, { state: "unknown", expected_revision: 0 },
      { state: [], expected_revision: 0 }, { state: "blocked", expected_revision: 0 },
      { state: "working", reason: {}, expected_revision: 0 },
      { state: "needs_input", reason: "x" * 1001, expected_revision: 0 }
    ].each do |payload|
      update_status(**payload)
      assert_response :unprocessable_entity, payload.inspect
      assert_equal 0, @chat.reload.work_status_revision
    end
  end

  test "nonparticipant cannot borrow the resident key owner's account authority" do
    @chat.chat_agents.destroy_all
    update_status(state: "working", expected_revision: 0)
    assert_response :not_found
    assert_nil @chat.reload.work_status
  end

  test "a seated guest may report but loses the door immediately on departure" do
    host = accounts(:team_account)
    membership = host.guest_memberships.create!(agent: @agent, added_by: @user)
    @chat = host.chats.create!(model_id: "openrouter/auto", agents: [ @agent ], manual_responses: true)
    update_status(state: "working", expected_revision: 0)
    assert_response :ok
    membership.destroy!
    update_status(state: "completed", expected_revision: 1)
    assert_response :not_found
    assert_equal "working", @chat.reload.work_status
  end

  test "guest membership is checked again even if a stale seat survived" do
    host = accounts(:team_account)
    membership = host.guest_memberships.create!(agent: @agent, added_by: @user)
    @chat = host.chats.create!(model_id: "openrouter/auto", agents: [ @agent ], manual_responses: true)
    membership.delete
    update_status(state: "working", expected_revision: 0)
    assert_response :not_found
    assert_nil @chat.reload.work_status
  end

  test "list and detail include untracked then reported state" do
    get "/api/v1/conversations/#{@chat.to_param}", headers: @headers
    assert_response :ok
    assert_equal 0, response.parsed_body.dig("conversation", "work_status", "revision")
    update_status(state: "completed", expected_revision: 0)
    get "/api/v1/conversations", headers: @headers
    row = response.parsed_body["conversations"].find { |chat| chat["id"] == @chat.to_param }
    assert_equal "completed", row.dig("work_status", "state")
  end

  test "a departed human account key and a site admin without membership cannot report" do
    @headers = { "Authorization" => "Bearer #{ApiKey.generate_for(@user, name: "Human work", account: @chat.account).raw_token}" }
    update_status(state: "working", expected_revision: 0)
    assert_response :ok
    @user.update!(is_site_admin: true)
    @user.memberships.where(account_id: @chat.account_id).delete_all
    update_status(state: "completed", expected_revision: 1)
    assert_response :not_found
    assert_equal "working", @chat.reload.work_status
  end

  test "an ineligible resident and a disabled destination cannot report" do
    @agent.update!(active: false)
    update_status(state: "working", expected_revision: 0)
    assert_response :not_found
    @agent.update!(active: true)
    @chat.account.update!(disabled_at: Time.current)
    update_status(state: "working", expected_revision: 0)
    assert_response :not_found
    assert_nil @chat.reload.work_status
  end

  private

  def update_status(**payload)
    patch "/api/v1/conversations/#{@chat.to_param}/work_status", params: payload, headers: @headers, as: :json
  end

end
