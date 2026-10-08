require "test_helper"
require "support/app_oauth_test_helper"

# The native app's reads, available on /api/v1 for any person's credential:
# who am I / sign out, the changes feed, activity status, live-update tickets,
# and invitations addressed to the person.
class Api::V1::AppParityTest < ActionDispatch::IntegrationTest

  include AppOauthTestHelper

  setup do
    @user = users(:existing_user)
    @personal = accounts(:existing_user_account)
    @team = accounts(:team_account)
    @client = create_app_client
    @tokens = sign_in_device
    @key = ApiKey.generate_for(@user, name: "My agent", account: @personal)
    @key_headers = { "Authorization" => "Bearer #{@key.raw_token}" }
    @team_chat = @team.chats.create!(model_id: "openrouter/auto", title: "Team room")
    @team_chat.messages.create!(role: "user", user: @user, content: "first")
    @team_chat.messages.create!(role: "user", user: @user, content: "second")
    resident_key = ApiKey.generate_for(users(:user_1), name: "Resident", agent: agents(:research_assistant))
    @resident_headers = { "Authorization" => "Bearer #{resident_key.raw_token}" }
  end

  # --- session ---------------------------------------------------------------

  test "session describes an OAuth credential and an API key" do
    get api_v1_session_url, headers: bearer(@tokens)
    assert_response :success
    assert_equal @user.email_address, response.parsed_body.dig("user", "email_address")
    assert_equal "app_session", response.parsed_body.dig("credential", "type")

    get api_v1_session_url, headers: @key_headers
    assert_response :success
    assert_equal "api_key", response.parsed_body.dig("credential", "type")
    assert_equal @personal.to_param, response.parsed_body.dig("credential", "account_id")
  end

  test "signing out an OAuth credential revokes the device session" do
    delete api_v1_session_url, headers: bearer(@tokens)
    assert_response :no_content
    get api_v1_session_url, headers: bearer(@tokens)
    assert_response :unauthorized
  end

  test "signing out an API key deletes that key and audits it" do
    assert_difference -> { AuditLog.where(action: "revoke_api_key").count }, 1 do
      delete api_v1_session_url, headers: @key_headers
    end
    assert_response :no_content
    assert_nil ApiKey.find_by(id: @key.id)
    assert_equal @key.id, AuditLog.where(action: "revoke_api_key").last.data["api_key_id"]
  end

  test "a resident key cannot sign itself out" do
    delete api_v1_session_url, headers: @resident_headers
    assert_response :forbidden
  end

  # --- changes feed and activity ---------------------------------------------

  test "the changes feed works in a second account without account_id" do
    get api_v1_conversation_changes_url(@team_chat), params: { since: 0 }, headers: bearer(@tokens)
    assert_response :success
    body = response.parsed_body
    assert_equal %w[first second], body["changes"].map { |c| c["content"] }
    assert_equal false, body["has_more"]

    get api_v1_conversation_changes_url(@team_chat), params: { since: body["next_since"] }, headers: bearer(@tokens)
    assert_empty response.parsed_body["changes"]
  end

  test "the changes feed requires since and refuses rooms outside the credential" do
    get api_v1_conversation_changes_url(@team_chat), headers: bearer(@tokens)
    assert_response :unprocessable_entity

    get api_v1_conversation_changes_url(@team_chat), params: { since: 0, account_id: @personal.to_param }, headers: bearer(@tokens)
    assert_response :not_found

    get api_v1_conversation_changes_url(@team_chat), params: { since: 0 }, headers: @key_headers
    assert_response :not_found, "a personal-account key does not reach the team's rooms"
  end

  test "the changes feed refuses a departed member and a disabled account" do
    memberships(:team_member).destroy!
    get api_v1_conversation_changes_url(@team_chat), params: { since: 0 }, headers: bearer(@tokens)
    assert_response :not_found

    personal_chat = @personal.chats.create!(model_id: "openrouter/auto", title: "Mine")
    @personal.update_columns(disabled_at: Time.current)
    get api_v1_conversation_changes_url(personal_chat), params: { since: 0 }, headers: @key_headers
    assert_response :not_found
  end

  test "resident keys use their own feeds, not the person's" do
    get api_v1_conversation_changes_url(@team_chat), params: { since: 0 }, headers: @resident_headers
    assert_response :forbidden
  end

  test "activity status is readable" do
    get api_v1_conversation_activity_url(@team_chat), headers: bearer(@tokens)
    assert_response :success
    assert_kind_of Array, response.parsed_body["activity"]
  end

  # --- live updates ----------------------------------------------------------

  test "an OAuth credential gets a cable ticket and an API key is told to poll" do
    post api_v1_cable_ticket_url, headers: bearer(@tokens)
    assert_response :created
    assert response.parsed_body["protocol"].start_with?(AppCableTicket::PROTOCOL_PREFIX)

    post api_v1_cable_ticket_url, headers: @key_headers
    assert_response :forbidden
  end

  # --- invitations -----------------------------------------------------------

  test "a person's credential lists and accepts invitations addressed to them" do
    inviting = Account.create!(name: "Inviting team", account_type: :team)
    invitation = Membership.create!(account: inviting, user: @user, role: "member", invited_by: users(:owner))

    get api_v1_invitations_url, headers: bearer(@tokens)
    assert_response :success
    assert_equal [ invitation.to_param ], response.parsed_body["invitations"].map { |i| i["id"] }

    post accept_api_v1_invitation_url(invitation), headers: bearer(@tokens)
    assert_response :success
    assert invitation.reload.confirmed?
    assert_includes @user.reload.confirmed_accounts, inviting
    audit = AuditLog.where(action: "accept_invitation").last
    assert_equal row_for(@tokens).app_session_id, audit.data["app_session_id"]

    get api_v1_invitations_url, headers: @key_headers
    assert_empty response.parsed_body["invitations"]
  end

  test "someone else's invitation and a disabled account's invitation are not found" do
    other = Membership.create!(account: Account.create!(name: "Elsewhere", account_type: :team),
                               user: users(:user_1), role: "member", invited_by: users(:owner))
    post accept_api_v1_invitation_url(other), headers: bearer(@tokens)
    assert_response :not_found

    closed = Account.create!(name: "Closed", account_type: :team, disabled_at: Time.current)
    mine = Membership.create!(account: closed, user: @user, role: "member", invited_by: users(:owner))
    post accept_api_v1_invitation_url(mine), headers: @key_headers
    assert_response :not_found
    assert_not mine.reload.confirmed?
  end

  test "a resident key cannot accept invitations" do
    get api_v1_invitations_url, headers: @resident_headers
    assert_response :forbidden
  end

end
