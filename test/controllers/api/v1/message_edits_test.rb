require "test_helper"

# Editing and deleting my own message through a person's key, with the same
# rules as messages#update/destroy and the native-app API.
class Api::V1::MessageEditsTest < ActionDispatch::IntegrationTest

  setup do
    @user = users(:user_1)
    @account = accounts(:personal_account)
    @chat = @account.chats.create!(model_id: "openrouter/auto", title: "Edits")
    @message = @chat.messages.create!(role: "user", user: @user, content: "Frist draft")
    @headers = { "Authorization" => "Bearer #{ApiKey.generate_for(@user, name: "Person's agent", account: @account).raw_token}" }
  end

  def path(message = @message, chat = @chat)
    api_v1_conversation_message_path(chat, message)
  end

  test "the author edits a message, which takes a new revision and is audited" do
    before = @message.revision
    patch path, params: { content: "First draft" }, headers: @headers, as: :json

    assert_response :success
    body = response.parsed_body["message"]
    assert_equal "First draft", body["content"]
    assert_equal false, body["discarded"]
    assert_operator body["revision"], :>, before
    assert_equal "First draft", @message.reload.content
    log = AuditLog.where(action: "update_message", auditable: @message).last
    assert_equal "Frist draft", log.data["old_content"]
  end

  test "the author deletes a message; a repeat returns the same marker and an edit is then 404" do
    assert_difference -> { AuditLog.where(action: "delete_message").count }, 1 do
      2.times do
        delete path, headers: @headers, as: :json
        assert_response :success
        assert_equal({ "id" => @message.to_param, "conversation_id" => @chat.to_param,
                       "revision" => @message.reload.revision, "discarded" => true }, response.parsed_body["message"])
      end
    end
    assert @message.discarded?
    patch path, params: { content: "Back" }, headers: @headers, as: :json
    assert_response :not_found
  end

  test "only the author may change a message" do
    reply = @chat.messages.create!(role: "assistant", content: "A reply")
    colleague = @chat.messages.create!(role: "user", user: users(:existing_user), content: "Theirs")
    [ reply, colleague ].each do |message|
      patch path(message), params: { content: "Mine now" }, headers: @headers, as: :json
      assert_response :forbidden
      delete path(message), headers: @headers, as: :json
      assert_response :forbidden
    end
    assert_equal "Theirs", colleague.reload.content
    assert_not reply.reload.discarded?
  end

  test "blank content is refused" do
    patch path, params: { content: "" }, headers: @headers, as: :json
    assert_response :unprocessable_entity
    assert_equal "Frist draft", @message.reload.content
  end

  test "another account's message is 404 and a resident key is refused" do
    foreign_chat = accounts(:existing_user_account).chats.create!(model_id: "openrouter/auto")
    foreign = foreign_chat.messages.create!(role: "user", user: @user, content: "Elsewhere")
    patch path(foreign, foreign_chat), params: { content: "x" }, headers: @headers, as: :json
    assert_response :not_found
    # A message id from another conversation is not found through this one.
    patch path(foreign, @chat), params: { content: "x" }, headers: @headers, as: :json
    assert_response :not_found

    agent = agents(:research_assistant)
    @chat.agents << agent
    resident = { "Authorization" => "Bearer #{ApiKey.generate_for(@user, name: "Resident", agent: agent).raw_token}" }
    patch path, params: { content: "x" }, headers: resident, as: :json
    assert_response :forbidden
    delete path, headers: resident, as: :json
    assert_response :forbidden
    assert_not @message.reload.discarded?
    assert_equal "Frist draft", @message.content
  end

end
