require "test_helper"

class Api::V1::MessageRestoresControllerTest < ActionDispatch::IntegrationTest

  setup do
    @user = users(:user_1)
    @user.update!(is_site_admin: true)
    @account = accounts(:personal_account)
    @account.update!(account_type: :team)
    @chat = @account.chats.create!(model_id: "openrouter/auto", title: "Recovery",
      manual_responses: true, agents: [ agents(:research_assistant) ])
    @message = @chat.messages.create!(role: "user", user: @user, content: "Retained message",
      client_message_id: SecureRandom.uuid,
      suppress_automatic_dispatch: true)
    @message.attachments.attach(io: StringIO.new("Retained bytes"), filename: "note.txt", content_type: "text/plain")
    @dispatch = MessageDispatch.accept!(message: @message, target_agent_ids: @chat.agent_ids)
    @message.reload
    @message.discard_as_author!
    @key = ApiKey.generate_for(@user, name: "Recovery operator", account: @account)
    @headers = { "Authorization" => "Bearer #{@key.raw_token}" }
  end

  test "system administrator restores once with a new revision retained bytes and no wake" do
    revision = @message.revision
    identity = @message.client_message_id
    assert_difference -> { AuditLog.where(action: "restore_message", auditable: @message).count }, 1 do
      assert_no_enqueued_jobs do
        2.times do
          post path, headers: @headers, as: :json
          assert_response :success
        end
      end
    end
    assert_not @message.reload.discarded?
    restored_revision = @message.revision
    assert_operator restored_revision, :>, revision
    assert_equal identity, @message.client_message_id
    assert_equal [ "cancelled", "discarded" ], @dispatch.reload.values_at(:status, :reason)
    assert_equal "Retained message", @message.content
    assert_equal "Retained bytes", @message.attachments.sole.download
    assert_equal({ "id" => @message.to_param, "conversation_id" => @chat.to_param,
                   "revision" => restored_revision, "discarded" => false }, response.parsed_body["message"])
    refute_includes response.body, "Retained message"
    log = AuditLog.where(action: "restore_message", auditable: @message).sole
    assert_equal @user, log.user
    assert_equal @key.id, log.data["api_key_id"]
    assert_equal @account, log.account
    post path, headers: @headers, as: :json
    assert_equal restored_revision, @message.reload.revision
  end

  test "ordinary account owner cannot restore" do
    @user.update!(is_site_admin: false)
    post path, headers: @headers, as: :json
    assert_response :forbidden
    assert @message.reload.discarded?
  end

  test "resident key is refused even when its provisioning user is an administrator" do
    key = ApiKey.generate_for(@user, name: "Resident", agent: agents(:research_assistant))
    post path, headers: { "Authorization" => "Bearer #{key.raw_token}" }, as: :json
    assert_response :forbidden
    assert @message.reload.discarded?
  end

  test "administrator must still have current confirmed membership" do
    memberships(:daniel_personal).update!(confirmed_at: nil)
    post path, headers: @headers, as: :json
    assert_response :not_found
    assert @message.reload.discarded?
  end

  test "disabled accounts discarded parents and mismatched message ids are hidden" do
    @account.update!(disabled_at: Time.current)
    post path, headers: @headers, as: :json
    assert_response :not_found
    @account.update!(disabled_at: nil)
    @chat.discard!
    post path, headers: @headers, as: :json
    assert_response :not_found
    @chat.undiscard!
    other = @account.chats.create!(model_id: "openrouter/auto")
    post api_v1_conversation_message_restore_path(other, @message), headers: @headers, as: :json
    assert_response :not_found
    assert @message.reload.discarded?
  end

  test "audit failure rolls back recovery and its sync revision" do
    revision = @message.revision
    AuditLog.stub(:create!, ->(**) { raise ActiveRecord::RecordInvalid }) do
      post path, headers: @headers, as: :json
      assert_response :unprocessable_entity
    end
    assert @message.reload.discarded?
    assert_equal revision, @message.revision
  end

  test "current audience including a member who joined after discard sees restored content" do
    newcomer = users(:confirmed_user)
    Membership.create!(account: @account, user: newcomer, role: "member", confirmed_at: Time.current)
    post path, headers: @headers, as: :json
    assert_response :success
    key = ApiKey.generate_for(newcomer, name: "Current member", account: @account)
    get api_v1_conversation_path(@chat), headers: { "Authorization" => "Bearer #{key.raw_token}" }
    assert_response :success
    assert_includes response.body, "Retained message"
  end

  private

  def path
    api_v1_conversation_message_restore_path(@chat, @message)
  end

end
