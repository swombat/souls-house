require "test_helper"
require "support/app_oauth_test_helper"

# The conversation-lifecycle endpoints with a native-app OAuth token. The
# token's person belongs to several accounts; authority and audit follow the
# room's own account, never the default.
class Api::V1::ConversationLifecycleOauthTest < ActionDispatch::IntegrationTest

  include AppOauthTestHelper

  setup do
    @user = users(:existing_user)
    @personal = accounts(:existing_user_account)
    @team = accounts(:team_account)
    @other_team = accounts(:another_team)
    # The personal account is the default, so the team account is a second,
    # non-default one.
    @user.update!(default_account_id: @personal.id)
    @client = create_app_client
    @tokens = sign_in_device
    @app_session = row_for(@tokens).app_session
    @team_chat = @team.chats.create!(model_id: "openrouter/auto", title: "Team room")
    @team_message = @team_chat.messages.create!(role: "user", user: @user, content: "Team draft")
  end

  def auth
    bearer(@tokens)
  end

  # (a) a write in the second, non-default account, without account_id ------

  test "the person's second account is the default's equal: archive, delete, edit, web access and listing" do
    assert_not_equal @team, @user.default_account

    post api_v1_conversation_archive_path(@team_chat), headers: auth, as: :json
    assert_response :success
    assert @team_chat.reload.archived?
    log = AuditLog.where(action: "archive_chat", auditable: @team_chat).last
    assert_equal @app_session.id, log.data["app_session_id"]
    assert_nil log.data["api_key_id"]
    assert_equal @team, log.account

    get api_v1_conversations_path, params: { filter: "archived" }, headers: auth
    assert_response :success
    assert_includes response.parsed_body["conversations"].map { |c| c["id"] }, @team_chat.to_param
    delete api_v1_conversation_archive_path(@team_chat), headers: auth, as: :json
    assert_response :success

    patch api_v1_conversation_message_path(@team_chat, @team_message), params: { content: "Team final" }, headers: auth, as: :json
    assert_response :success
    assert_equal "Team final", @team_message.reload.content
    edit_log = AuditLog.where(action: "update_message", auditable: @team_message).last
    assert_equal @app_session.id, edit_log.data["app_session_id"]
    assert_equal @team, edit_log.account

    patch api_v1_conversation_path(@team_chat), params: { web_access: true }, headers: auth, as: :json
    assert_response :success
    assert @team_chat.reload.web_access

    # Only a room with residents' manual responses can be forked, as on the web.
    forkable = @team.chats.new(model_id: "openrouter/auto", title: "Team plans", manual_responses: true)
    forkable.agent_ids = [ agents(:other_account_agent).id ]
    forkable.save!
    post api_v1_conversation_fork_path(forkable), headers: auth, as: :json
    assert_response :created
    forked = Chat.find(response.parsed_body.dig("conversation", "id"))
    assert_equal @team, forked.account
    assert_equal @team, AuditLog.where(action: "fork_chat", auditable: forked).last.account

    post api_v1_conversation_discard_path(@team_chat), headers: auth, as: :json
    assert_response :success
    assert @team_chat.reload.discarded?
    assert_equal @app_session.id, AuditLog.where(action: "discard_chat", auditable: @team_chat).last.data["app_session_id"]
    get api_v1_conversations_path, params: { filter: "deleted" }, headers: auth
    assert_response :success
    assert_includes response.parsed_body["conversations"].map { |c| c["id"] }, @team_chat.to_param
  end

  # (b) account_id naming a different account of theirs ---------------------

  test "account_id naming another of the person's accounts refuses the room" do
    narrowed = { account_id: @other_team.to_param }
    post api_v1_conversation_archive_path(@team_chat, narrowed), headers: auth, as: :json
    assert_response :not_found
    patch api_v1_conversation_message_path(@team_chat, @team_message, narrowed), params: { content: "x" }, headers: auth, as: :json
    assert_response :not_found
    patch api_v1_conversation_path(@team_chat, narrowed), params: { web_access: true }, headers: auth, as: :json
    assert_response :not_found
    post api_v1_conversation_discard_path(@team_chat, narrowed), headers: auth, as: :json
    assert_response :not_found
    get api_v1_conversations_path, params: { filter: "archived" }.merge(narrowed), headers: auth
    assert_response :success
    assert_not_includes response.parsed_body["conversations"].map { |c| c["id"] }, @team_chat.to_param

    @team_chat.reload
    assert_not @team_chat.archived?
    assert_not @team_chat.discarded?
    assert_not @team_chat.web_access
    assert_equal "Team draft", @team_message.reload.content

    # Narrowed to the room's own account, it works.
    post api_v1_conversation_archive_path(@team_chat, account_id: @team.to_param), headers: auth, as: :json
    assert_response :success
  end

  # (c) disabled account and departed member ---------------------------------

  def assert_team_room_unreachable
    @team_chat.archive!
    get api_v1_conversations_path, params: { filter: "archived" }, headers: auth
    assert_not_includes Array(response.parsed_body["conversations"]).map { |c| c["id"] }, @team_chat.to_param
    get api_v1_conversations_path, params: { filter: "archived", account_id: @team.to_param }, headers: auth
    assert_response :not_found
    @team_chat.unarchive!

    post api_v1_conversation_archive_path(@team_chat), headers: auth, as: :json
    assert_response :not_found
    patch api_v1_conversation_message_path(@team_chat, @team_message), params: { content: "x" }, headers: auth, as: :json
    assert_response :not_found
    patch api_v1_conversation_path(@team_chat), params: { model_id: "anthropic/claude-opus-4" }, headers: auth, as: :json
    assert_response :not_found
    post api_v1_conversation_discard_path(@team_chat), headers: auth, as: :json
    assert_response :not_found

    @team_chat.reload
    assert_not @team_chat.archived?
    assert_not @team_chat.discarded?
    assert_equal "openrouter/auto", @team_chat.model_id
    assert_equal "Team draft", @team_message.reload.content
  end

  test "a disabled account's room is 404" do
    @team.update!(disabled_at: Time.current)
    assert_team_room_unreachable
  end

  test "a departed member gets 404" do
    memberships(:team_member).destroy!
    assert_team_room_unreachable
  end

  # (d) a resident key --------------------------------------------------------

  test "a resident key is refused" do
    agent = agents(:research_assistant)
    resident = { "Authorization" => "Bearer #{ApiKey.generate_for(users(:user_1), name: "Resident", agent: agent).raw_token}" }
    room = agent.account.chats.create!(model_id: "openrouter/auto", title: "Resident room")
    room.agents << agent
    post api_v1_conversation_archive_path(room), headers: resident, as: :json
    assert_response :forbidden
    get api_v1_conversations_path, params: { filter: "archived" }, headers: resident
    assert_response :forbidden
    assert_not room.reload.archived?
  end

end
