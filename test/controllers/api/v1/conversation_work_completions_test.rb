require "test_helper"

class Api::V1::ConversationWorkCompletionsTest < ActionDispatch::IntegrationTest

  setup do
    @user = users(:user_1)
    @agent = agents(:research_assistant)
    @chat = @agent.account.chats.create!(title: "Completion API", model_id: "openrouter/auto",
      agents: [ @agent ], manual_responses: true)
    @resident = { "Authorization" => "Bearer #{ApiKey.generate_for(@user, name: "Completion", agent: @agent).raw_token}" }
    @human = human_headers(@chat.account)
    @fields = { changes_summary: "Implementation", result: "PR 1", checks: "Green", remaining: "None",
      request_key: "one", expected_revision: 0 }
  end

  test "resident submits but cannot accept grant or revoke even through its human key owner" do
    submit
    assert_response :ok
    id = response.parsed_body.dig("completion", "id")
    %w[accept grant].each do |action|
      post "#{path}/#{action}", params: { id: id, expected_revision: 1, auto_close: true }, headers: @resident, as: :json
      assert_response :forbidden
    end
    delete "#{path}/revoke", params: { expected_revision: 1 }, headers: @resident, as: :json
    assert_response :forbidden
    assert_equal "ready_for_review", @chat.reload.work_status
    assert_not @chat.archived?
  end

  test "confirmed host human accepts exact handoff and repeat returns receipt without re-closing" do
    submit
    id = response.parsed_body.dig("completion", "id")
    2.times do
      post "#{path}/accept", params: { id: id, expected_revision: 1, auto_close: true }, headers: @human, as: :json
      assert_response :ok
      assert response.parsed_body["archived"]
    end
    assert @chat.reload.archived?
    assert_equal 2, @chat.work_status_revision
  end

  test "malformed fields revisions and booleans cannot grant or persist completion" do
    [ @fields.merge(expected_revision: "0"), @fields.merge(checks: nil),
      @fields.merge(request_key: []), @fields.merge(result: "bad\0field") ].each do |fields|
      submit(fields)
      assert_response :unprocessable_entity
    end
    assert_empty @chat.work_completions
    post "#{path}/grant", params: { expected_revision: 0, auto_close: "true" }, headers: @human, as: :json
    assert_response :unprocessable_entity
    assert_empty @chat.work_completion_permissions
  end

  test "departed human and outside account cannot accept or grant" do
    submit
    id = response.parsed_body.dig("completion", "id")
    @user.memberships.where(account_id: @chat.account_id).delete_all
    @user.update!(is_site_admin: true)
    post "#{path}/accept", params: { id: id, expected_revision: 1, auto_close: true }, headers: @human, as: :json
    assert_response :not_found
    post "#{path}/grant", params: { expected_revision: 1, auto_close: true }, headers: @human, as: :json
    assert_response :not_found
    assert_nil @chat.work_completions.sole.accepted_at
  end

  test "host permission allows guest to complete but never automatically archive the host chat" do
    host = accounts(:team_account)
    host.guest_memberships.create!(agent: @agent, added_by: @user)
    @chat = host.chats.create!(title: "Guest completion", model_id: "openrouter/auto",
      agents: [ @agent ], manual_responses: true)
    @human = human_headers(host)
    post "#{path}/grant", params: { expected_revision: 0, auto_close: true }, headers: @human, as: :json
    assert_response :ok
    submit
    assert_response :ok
    assert response.parsed_body.dig("completion", "accepted_at")
    assert_equal "guest_cannot_auto_close", response.parsed_body.dig("completion", "closure_blocked", "code")
    assert_not @chat.reload.archived?
    host.guest_memberships.find_by!(agent: @agent).destroy!
    get path, headers: @resident
    assert_response :not_found
  end

  test "human grants can be revoked and a new handoff defaults to review" do
    post "#{path}/grant", params: { expected_revision: 0, auto_close: true }, headers: @human, as: :json
    assert_response :ok
    delete "#{path}/revoke", params: { expected_revision: 0 }, headers: @human, as: :json
    assert_response :ok
    submit
    assert_response :ok
    assert_nil response.parsed_body.dig("completion", "accepted_at")
  end

  private

  def path
    "/api/v1/conversations/#{@chat.to_param}/work_completion"
  end

  def submit(fields = @fields)
    post path, params: fields, headers: @resident, as: :json
  end

  def human_headers(account)
    { "Authorization" => "Bearer #{ApiKey.generate_for(@user, name: "Human completion", account: account).raw_token}" }
  end

end
