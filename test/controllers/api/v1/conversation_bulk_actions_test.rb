require "test_helper"

# The bulk conversation actions for a person's key, as the web sidebar's
# Actions menu does them (Chats::BulkActionsController).
class Api::V1::ConversationBulkActionsTest < ActionDispatch::IntegrationTest

  setup do
    @user = users(:user_1)
    @account = accounts(:personal_account)
    @chats = 2.times.map { |i| @account.chats.create!(model_id: "openrouter/auto", title: "Bulk #{i}") }
    @asks = @chats.map do |chat|
      ask = chat.messages.create!(role: "assistant", content: "Test User, please reply")
      chat.with_lock { ReplyExpectation.record!(message: ask, user: @user, score: 0.95) }
      ask
    end
    @tag = @account.visual_tags.create!(label: "Done", icon: "Check", colour: "rose")
    @headers = { "Authorization" => "Bearer #{ApiKey.generate_for(@user, name: "Person's agent", account: @account).raw_token}" }
  end

  test "marks many conversations read in one request" do
    post "/api/v1/conversations/bulk/mark_read", params: { conversation_ids: @chats.map(&:to_param) }, headers: @headers, as: :json
    assert_response :ok
    assert_equal @chats.map(&:to_param).sort, response.parsed_body["conversation_ids"].sort
    @asks.each { |ask| assert ReplyExpectation.find_by!(message: ask, user: @user).state_dismissed? }

    get api_v1_reply_attention_path, headers: @headers
    assert_equal 0, response.parsed_body["total"]
  end

  test "tags many conversations in one request, and validates the tag" do
    patch "/api/v1/conversations/bulk/visual_tag", params: { conversation_ids: @chats.map(&:to_param), visual_tag_id: @tag.to_param },
      headers: @headers, as: :json
    assert_response :ok
    @chats.each { |chat| assert_equal @tag, chat.reload.visual_tag }

    patch "/api/v1/conversations/bulk/visual_tag", params: { conversation_ids: @chats.map(&:to_param), visual_tag_id: "" },
      headers: @headers, as: :json
    assert_response :unprocessable_entity
    patch "/api/v1/conversations/bulk/visual_tag", params: { conversation_ids: [ "12" ], visual_tag_id: nil },
      headers: @headers, as: :json
    assert_response :unprocessable_entity
    @chats.each { |chat| assert_equal @tag, chat.reload.visual_tag }
  end

  test "the routes do not swallow a conversation called bulk" do
    patch "/api/v1/conversations/#{@chats[0].to_param}", params: { title: "Still mine" }, headers: @headers, as: :json
    assert_response :ok
    assert_equal "Still mine", @chats[0].reload.title
  end

end
