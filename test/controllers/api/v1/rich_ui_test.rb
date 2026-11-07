require "test_helper"

class Api::V1::RichUiTest < ActionDispatch::IntegrationTest

  setup do
    @user = users(:confirmed_user)
    @account = @user.personal_account
    @agent = agents(:research_assistant)
    @agent.update_columns(account_id: @account.id)
    @chat = @account.chats.create!(model_id: "openrouter/auto", title: "Rich UI", manual_responses: true, agents: [ @agent ])
    key = ApiKey.generate_for(@user, name: "Synthetic rich UI", agent: @agent)
    @headers = { "Authorization" => "Bearer #{key.raw_token}" }
    @spec = { "version" => 1, "root" => "table", "elements" => {
      "table" => { "type" => "Table", "props" => { "columns" => [ "Value" ], "rows" => [ [ 42 ], [ nil ], [ "1,234" ] ] } }
    } }
  end

  test "resident posts and reads rich UI through the authorized conversation" do
    assert_difference "Message.count", 1 do
      post api_v1_conversation_messages_url(@chat),
        params: { content: "The value is 42", rich_ui: @spec }, headers: @headers, as: :json
    end
    assert_response :created
    record = @chat.messages.last
    assert_equal @spec, record.rich_ui
    get rich_ui_api_v1_conversation_message_url(@chat, record), headers: @headers
    assert_response :success
    assert_equal @spec, response.parsed_body["rich_ui"]
    assert_equal "no-store", response.headers["Cache-Control"]
    get api_v1_conversation_url(@chat), headers: @headers
    entry = response.parsed_body.dig("conversation", "transcript").last
    assert entry["rich_ui_summary"].present?
    assert_not entry.key?("rich_ui")
  end

  test "rejects invalid payload atomically and requires prose fallback" do
    [ {}, [], "invalid", @spec.merge("on" => {}) ].each do |invalid|
      assert_no_difference "Message.count" do
        post api_v1_conversation_messages_url(@chat),
          params: { content: "Bad UI", rich_ui: invalid }, headers: @headers, as: :json
      end
      assert_response :unprocessable_entity
    end
    assert_no_difference "Message.count" do
      post api_v1_conversation_messages_url(@chat),
        params: { content: "", rich_ui: @spec }, headers: @headers, as: :json
    end
    assert_response :unprocessable_entity
  end

  test "designated fallback round trips without removing transcript prose" do
    spec = @spec.merge("fallback" => "The value is 42")
    content = "My caption\n\nThe value is 42"
    post api_v1_conversation_messages_url(@chat),
      params: { content: content, rich_ui: spec }, headers: @headers, as: :json
    assert_response :created
    record = @chat.messages.last
    assert_equal content, record.content
    assert_equal spec, record.as_json["rich_ui"]
    get rich_ui_api_v1_conversation_message_url(@chat, record), headers: @headers
    assert_equal spec, response.parsed_body["rich_ui"]
    get api_v1_conversation_url(@chat), headers: @headers
    entry = response.parsed_body.dig("conversation", "transcript").last
    assert_equal content, entry["content"]
    assert_not entry.key?("rich_ui")
    assert_no_difference "Message.count" do
      post api_v1_conversation_messages_url(@chat),
        params: { content: "Unrelated prose", rich_ui: spec }, headers: @headers, as: :json
    end
    assert_response :unprocessable_entity
  end

  test "human keys cannot submit rich UI" do
    key = ApiKey.generate_for(@user, name: "Synthetic human")
    assert_no_difference "Message.count" do
      post api_v1_conversation_messages_url(@chat), params: { content: "Hi", rich_ui: @spec },
        headers: { "Authorization" => "Bearer #{key.raw_token}" }, as: :json
    end
    assert_response :unprocessable_entity
  end

  test "on demand read cannot cross conversations accounts or discarded messages" do
    record = @chat.messages.create!(content: "42", role: "assistant", agent: @agent, rich_ui: @spec)
    other = @account.chats.create!(model_id: "openrouter/auto", title: "Not joined")
    get rich_ui_api_v1_conversation_message_url(other, record), headers: @headers
    assert_response :not_found
    foreign = accounts(:team_account).chats.create!(model_id: "openrouter/auto", title: "Foreign")
    get rich_ui_api_v1_conversation_message_url(foreign, record), headers: @headers
    assert_response :not_found
    record.discard!
    get rich_ui_api_v1_conversation_message_url(@chat, record), headers: @headers
    assert_response :not_found
  end

end
