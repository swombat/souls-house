require "test_helper"

class DiscardedChatVisibilityTest < ActionDispatch::IntegrationTest

  setup do
    @user = users(:user_1)
    @agent = agents(:research_assistant)
    @account = @agent.account
    @chat = @account.chats.create!(title: "Retained conversation", model_id: "openrouter/auto",
      manual_responses: true, agents: [ @agent ], summary: "Retained summary")
    @message = @chat.messages.create!(role: "user", user: @user, content: "Retained private content",
      suppress_automatic_dispatch: true)
    @message.attachments.attach(io: StringIO.new("Retained file"), filename: "note.txt", content_type: "text/plain")
    @attachment = @message.attachments_attachments.sole
    @human_key = ApiKey.generate_for(@user, name: "Visibility", account: @account)
    @resident_key = ApiKey.generate_for(@user, name: "Resident visibility", agent: @agent)
    @chat.discard!
  end

  test "ordinary web reads and mutations cannot reach a discarded parent" do
    sign_in @user
    [
      account_chat_path(@account, @chat),
      activity_account_chat_path(@account, @chat),
      account_chat_messages_path(@account, @chat),
      account_chat_draft_path(@account, @chat)
    ].each do |path|
      get path, as: :json
      assert_response :not_found
      refute_includes response.body, "Retained private content"
    end

    patch message_path(@message), params: { message: { content: "Changed" } }, as: :json
    assert_response :not_found
    assert_equal "Retained private content", @message.reload.content
    post account_chat_fork_path(@account, @chat)
    assert_response :not_found
    assert_no_enqueued_jobs do
      post message_voice_path(@message), as: :json
    end
    assert_response :not_found
  end

  test "human and resident APIs deny parent transcript and attachment reads" do
    [ @human_key, @resident_key ].each do |key|
      headers = { "Authorization" => "Bearer #{key.raw_token}" }
      get api_v1_conversation_path(@chat), headers: headers
      assert_response :not_found
      get api_v1_conversation_message_attachment_path(@chat, @message, @attachment), headers: headers
      assert_response :not_found
    end

    get api_v1_conversation_draft_path(@chat), headers: { "Authorization" => "Bearer #{@human_key.raw_token}" }
    assert_response :not_found
  end

  test "deleted API listing retains recovery metadata without the summary" do
    get api_v1_conversations_path, params: { filter: "deleted" },
      headers: { "Authorization" => "Bearer #{@human_key.raw_token}" }
    assert_response :success
    chat = response.parsed_body.fetch("conversations").find { |row| row["id"] == @chat.to_param }
    assert chat
    assert_nil chat["summary"]
    refute_includes response.body, "Retained summary"
  end

  test "parent restore does not restore independently discarded children or enqueue a wake" do
    hidden = @chat.messages.create!(role: "user", user: @user, content: "Independently discarded",
      suppress_automatic_dispatch: true)
    hidden.discard!
    sign_in @user
    assert_no_enqueued_jobs do
      delete account_chat_discard_path(@account, @chat)
    end
    assert_redirected_to account_chats_path(@account)
    assert_not @chat.reload.discarded?
    assert hidden.reload.discarded?
    get account_chat_messages_path(@account, @chat), as: :json
    assert_response :success
    assert_includes response.body, "Retained private content"
    refute_includes response.body, "Independently discarded"
    assert_equal "Retained file", @attachment.blob.download
  end

  test "restoring a parent still requires its current account authority" do
    sign_in users(:confirmed_user)
    delete account_chat_discard_path(@account, @chat)
    assert_response :not_found
    assert @chat.reload.discarded?
  end

end
