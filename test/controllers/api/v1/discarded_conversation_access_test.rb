require "test_helper"

class Api::V1::DiscardedConversationAccessTest < ActionDispatch::IntegrationTest

  setup do
    @user = users(:user_1)
    @account = accounts(:personal_account)
    @agent = agents(:research_assistant)
    @chat = @account.chats.create!(
      model_id: "openrouter/auto", title: "Discard access", manual_responses: true, agents: [ @agent ]
    )
    @message = @chat.messages.create!(role: "user", user: @user, content: "Retained words")
    @message.attachments.attach(io: StringIO.new("Synthetic file"), filename: "example.txt", content_type: "text/plain")
    @attachment = @message.attachments_attachments.sole
    @human_key = ApiKey.generate_for(@user, name: "Human discard access", account: @account)
    @resident_key = ApiKey.generate_for(@user, name: "Resident discard access", agent: @agent)
    @human_headers = { "Authorization" => "Bearer #{@human_key.raw_token}" }
    @resident_headers = { "Authorization" => "Bearer #{@resident_key.raw_token}" }
  end

  test "resident can read a kept conversation but not a discarded one until restored" do
    assert_readable(@resident_headers)

    @chat.discard!
    get api_v1_conversation_path(@chat), headers: @resident_headers
    assert_response :not_found
    assert_equal({ "error" => "Not found" }, response.parsed_body)

    @chat.undiscard!
    assert_readable(@resident_headers)
  end

  test "resident can download from a kept conversation but not a discarded one until restored" do
    assert_downloadable(@resident_headers)

    @chat.discard!
    get attachment_path, headers: @resident_headers
    assert_response :not_found
    assert_equal({ "error" => "Not found" }, response.parsed_body)

    @chat.undiscard!
    assert_downloadable(@resident_headers)
  end

  test "human manager can list read download and restore a discarded conversation" do
    @chat.discard!

    get api_v1_conversations_path, params: { filter: "deleted" }, headers: @human_headers
    assert_response :success
    assert_includes response.parsed_body["conversations"].map { |chat| chat["id"] }, @chat.to_param
    assert_readable(@human_headers)
    assert_downloadable(@human_headers)

    delete api_v1_conversation_discard_path(@chat), headers: @human_headers
    assert_response :success
    assert_not @chat.reload.discarded?
    assert_readable(@human_headers)
    assert_downloadable(@human_headers)
  end

  test "same-account resident without a seat cannot read or download before discard or after restore" do
    outsider = agents(:code_reviewer)
    assert_equal @chat.account_id, outsider.account_id
    assert_not @chat.agents.exists?(outsider.id)
    key = ApiKey.generate_for(@user, name: "Same-account outsider", agent: outsider)
    headers = { "Authorization" => "Bearer #{key.raw_token}" }

    assert_inaccessible_through_discard_and_restore(@chat, @message, @attachment, headers)
  end

  test "resident cannot read or download an unrelated account conversation before discard or after restore" do
    chat = accounts(:team_account).chats.create!(
      model_id: "openrouter/auto", title: "Unrelated account", manual_responses: true,
      agents: [ agents(:other_account_agent) ]
    )
    assert_not_equal @agent.account_id, chat.account_id
    assert_not chat.agents.exists?(@agent.id)
    message = chat.messages.create!(role: "user", user: @user, content: "Unrelated words")
    message.attachments.attach(io: StringIO.new("Unrelated synthetic file"), filename: "unrelated.txt", content_type: "text/plain")

    assert_inaccessible_through_discard_and_restore(
      chat, message, message.attachments_attachments.sole, @resident_headers
    )
  end

  test "discarded messages remain hidden from humans and residents even after conversation restore" do
    @message.discard!
    @chat.discard!
    @chat.undiscard!

    [ @human_headers, @resident_headers ].each do |headers|
      get api_v1_conversation_path(@chat), headers: headers
      assert_response :success
      assert_empty response.parsed_body.dig("conversation", "transcript")

      get attachment_path, headers: headers
      assert_response :not_found
    end
  end

  private

  def assert_inaccessible_through_discard_and_restore(chat, message, attachment, headers)
    [ :kept, :discarded, :restored ].each do |state|
      chat.discard! if state == :discarded
      chat.undiscard! if state == :restored

      get api_v1_conversation_path(chat), headers: headers
      assert_response :not_found, "show when #{state}"
      assert_equal({ "error" => "Not found" }, response.parsed_body)

      get api_v1_conversation_message_attachment_path(chat, message, attachment), headers: headers
      assert_response :not_found, "download when #{state}"
      assert_equal({ "error" => "Not found" }, response.parsed_body)
    end
  end

  def attachment_path
    api_v1_conversation_message_attachment_path(@chat, @message, @attachment)
  end

  def assert_readable(headers)
    get api_v1_conversation_path(@chat), headers: headers
    assert_response :success
    assert_equal @chat.to_param, response.parsed_body.dig("conversation", "id")
    assert_equal [ @message.to_param ], response.parsed_body.dig("conversation", "transcript").map { |message| message["id"] }
  end

  def assert_downloadable(headers)
    get attachment_path, headers: headers
    assert_response :redirect
    assert response.location.present?
  end

end
