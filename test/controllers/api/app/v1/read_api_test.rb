require "test_helper"
require "support/app_oauth_test_helper"

# Issue #94 B, step 4a: the read side of /api/app/v1. Authority is the token's
# user intersected with current confirmed membership, re-checked per request.
class Api::App::V1::ReadApiTest < ActionDispatch::IntegrationTest

  include AppOauthTestHelper

  setup do
    @user = users(:existing_user)
    @account = accounts(:existing_user_account)
    @client = create_app_client
    @tokens = sign_in_device
    @chat = @account.chats.create!(model_id: "openrouter/auto", title: "Phone chat")
  end

  # --- accounts --------------------------------------------------------------

  test "accounts lists only confirmed memberships of enabled accounts" do
    invited = Account.create!(name: "Invited team", account_type: :team)
    Membership.create!(account: invited, user: @user, role: "member", invited_by: users(:owner))
    disabled = Account.create!(name: "Disabled team", account_type: :team, disabled_at: Time.current)
    Membership.create!(account: disabled, user: @user, role: "member", confirmed_at: Time.current)

    get "/api/app/v1/accounts", headers: bearer(@tokens)
    assert_response :success
    listed = response.parsed_body["accounts"]
    assert_equal [ @account, accounts(:team_account), accounts(:another_team) ].map(&:to_param).sort, listed.map { |a| a["id"] }.sort
    assert_equal({ "id" => @account.to_param, "name" => @account.name, "type" => "personal", "role" => "owner" },
                 listed.find { |a| a["id"] == @account.to_param })
  end

  # --- conversations ---------------------------------------------------------

  test "conversations lists kept human-visible chats, active before archived" do
    archived = @account.chats.create!(model_id: "openrouter/auto", title: "Old")
    archived.update!(archived_at: Time.current)
    @account.chats.create!(model_id: "openrouter/auto", title: "Gone").discard!
    @account.chats.create!(model_id: "openrouter/auto", title: "#{Chat::AGENT_ONLY_PREFIX} backstage")

    get "/api/app/v1/accounts/#{@account.to_param}/conversations", headers: bearer(@tokens)
    assert_response :success
    convs = response.parsed_body["conversations"]
    assert_equal [ @chat.to_param, archived.to_param ], convs.map { |c| c["id"] }
    assert_equal false, convs.first["archived"]
    assert_equal true, convs.last["archived"]
    assert_equal @chat.reload.message_revision, convs.first["latest_revision"]
  end

  test "another user's account is 404, not 403" do
    get "/api/app/v1/accounts/#{accounts(:regular_user_account).to_param}/conversations", headers: bearer(@tokens)
    assert_error :not_found, "not_found"
  end

  test "membership is re-checked on every request with the same token" do
    team = accounts(:team_account)
    membership = memberships(:team_member)
    team_chat = team.chats.create!(model_id: "openrouter/auto", title: "Team")

    get "/api/app/v1/conversations/#{team_chat.to_param}/changes", params: { since: 0 }, headers: bearer(@tokens)
    assert_response :success

    membership.destroy!
    get "/api/app/v1/conversations/#{team_chat.to_param}/changes", params: { since: 0 }, headers: bearer(@tokens)
    assert_error :not_found, "not_found"
    get "/api/app/v1/conversations/#{team_chat.to_param}/messages", headers: bearer(@tokens)
    assert_error :not_found, "not_found"
    get "/api/app/v1/accounts/#{team.to_param}/conversations", headers: bearer(@tokens)
    assert_error :not_found, "not_found"
  end

  test "a discarded conversation and a malformed id are both 404" do
    @chat.discard!
    get "/api/app/v1/conversations/#{@chat.to_param}/messages", headers: bearer(@tokens)
    assert_error :not_found, "not_found"
    get "/api/app/v1/conversations/not-an-id/messages", headers: bearer(@tokens)
    assert_error :not_found, "not_found"
  end

  test "a revoked device session can't read" do
    AppSession.find(row_for(@tokens).app_session_id).revoke!(:logout)
    get "/api/app/v1/accounts", headers: bearer(@tokens)
    assert_error :unauthorized, "unauthorized"
  end

  # --- messages (history) ----------------------------------------------------

  test "history pages back with before, hides discarded, and shows client ids only to their author" do
    mine = @chat.messages.create!(role: "user", user: @user, content: "one", client_message_id: "c-1", submission_digest: "d")
    other_user = users(:regular_user)
    theirs = @chat.messages.create!(role: "user", user: other_user, content: "two", client_message_id: "c-2", submission_digest: "d")
    hidden = @chat.messages.create!(role: "user", user: @user, content: "three")
    hidden.discard!
    last = @chat.messages.create!(role: "assistant", agent: agents(:research_assistant), content: "four")

    get "/api/app/v1/conversations/#{@chat.to_param}/messages", params: { limit: 2 }, headers: bearer(@tokens)
    assert_response :success
    body = response.parsed_body
    assert_equal [ theirs.to_param, last.to_param ], body["messages"].map { |m| m["id"] }
    assert body["has_more"]
    assert_nil body["messages"].first["client_message_id"], "another human's client id is not exposed"
    assert_equal({ "type" => "agent", "id" => agents(:research_assistant).to_param, "name" => agents(:research_assistant).name },
                 body["messages"].last["author"])

    get "/api/app/v1/conversations/#{@chat.to_param}/messages", params: { limit: 2, before: body["oldest_id"] }, headers: bearer(@tokens)
    body = response.parsed_body
    assert_equal [ mine.to_param ], body["messages"].map { |m| m["id"] }
    assert_equal "c-1", body["messages"].first["client_message_id"]
    assert_not body["has_more"]
  end

  # --- changes (reconciliation) ----------------------------------------------

  test "since is required and validated" do
    get "/api/app/v1/conversations/#{@chat.to_param}/changes", headers: bearer(@tokens)
    assert_error :unprocessable_entity, "invalid_parameter"
    get "/api/app/v1/conversations/#{@chat.to_param}/changes", params: { since: -1 }, headers: bearer(@tokens)
    assert_error :unprocessable_entity, "invalid_parameter"
    get "/api/app/v1/conversations/#{@chat.to_param}/changes", params: { since: "1e3" }, headers: bearer(@tokens)
    assert_error :unprocessable_entity, "invalid_parameter"
    get "/api/app/v1/conversations/#{@chat.to_param}/changes", params: { since: 0, limit: 501 }, headers: bearer(@tokens)
    assert_error :unprocessable_entity, "invalid_parameter"
  end

  test "bootstrap from since=0 returns every message in revision order, discarded ones as bare markers" do
    a = @chat.messages.create!(role: "user", user: @user, content: "hello")
    b = @chat.messages.create!(role: "user", user: @user, content: "secret")
    b.discard!

    get "/api/app/v1/conversations/#{@chat.to_param}/changes", params: { since: 0 }, headers: bearer(@tokens)
    assert_response :success
    body = response.parsed_body
    assert_equal [ a.to_param, b.to_param ], body["changes"].map { |c| c["id"] }
    assert_equal "hello", body["changes"].first["content"]
    marker = body["changes"].last
    assert_equal({ "id" => b.to_param, "conversation_id" => @chat.to_param, "revision" => b.reload.revision, "discarded" => true }, marker)
    assert_not_includes response.body, "secret", "a marker never carries retained content"
    assert_equal b.revision, body["next_since"]
    assert_equal @chat.reload.message_revision, body["latest_revision"]
    assert_equal false, body["has_more"]
  end

  test "an empty page keeps the cursor" do
    @chat.messages.create!(role: "user", user: @user, content: "hello")
    head = @chat.reload.message_revision

    get "/api/app/v1/conversations/#{@chat.to_param}/changes", params: { since: head }, headers: bearer(@tokens)
    assert_response :success
    assert_equal({ "changes" => [], "next_since" => head, "has_more" => false, "latest_revision" => head }, response.parsed_body)
  end

  test "paging during edits never skips: next_since is the last row returned" do
    first = @chat.messages.create!(role: "user", user: @user, content: "m1")
    @chat.messages.create!(role: "user", user: @user, content: "m2")
    third = @chat.messages.create!(role: "user", user: @user, content: "m3")

    get "/api/app/v1/conversations/#{@chat.to_param}/changes", params: { since: 0, limit: 2 }, headers: bearer(@tokens)
    page1 = response.parsed_body
    assert page1["has_more"]
    assert_equal 2, page1["changes"].size
    assert_equal page1["changes"].last["revision"], page1["next_since"]

    # Between pages: an already-seen row is edited, and an unseen one discarded.
    first.update!(content: "m1 edited")
    third.discard!

    get "/api/app/v1/conversations/#{@chat.to_param}/changes", params: { since: page1["next_since"], limit: 2 }, headers: bearer(@tokens)
    page2 = response.parsed_body
    assert_equal [ first.to_param, third.to_param ], page2["changes"].map { |c| c["id"] }
    assert_equal "m1 edited", page2["changes"].first["content"]
    assert page2["changes"].last["discarded"]
    assert_not page2["has_more"]
  end

  test "a write between snapshot and follow-up is returned by the follow-up" do
    @chat.messages.create!(role: "user", user: @user, content: "before")
    get "/api/app/v1/conversations/#{@chat.to_param}/changes", params: { since: 0 }, headers: bearer(@tokens)
    snapshot = response.parsed_body

    late = @chat.messages.create!(role: "assistant", agent: agents(:research_assistant), content: "late reply")
    get "/api/app/v1/conversations/#{@chat.to_param}/changes", params: { since: snapshot["next_since"] }, headers: bearer(@tokens)
    assert_equal [ late.to_param ], response.parsed_body["changes"].map { |c| c["id"] }
  end

  # --- error shape -----------------------------------------------------------

  test "errors have one shape and carry the request id, which is also a header" do
    get "/api/app/v1/conversations/not-an-id/changes", params: { since: 0 }, headers: bearer(@tokens).merge("X-Request-Id" => "req-abc-123")
    assert_response :not_found
    assert_equal "req-abc-123", response.headers["X-Request-Id"]
    assert_equal({ "code" => "not_found", "message" => "Not found", "details" => {}, "request_id" => "req-abc-123" },
                 response.parsed_body["error"])
  end

  private

  def assert_error(status, code)
    assert_response status
    assert_equal code, response.parsed_body.dig("error", "code")
    assert response.parsed_body.dig("error", "request_id").present?
  end

end
