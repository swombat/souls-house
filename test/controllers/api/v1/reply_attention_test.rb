require "test_helper"

# Where the key's person was asked to respond, and dismissing those flags,
# as chats/reply_dismissals does on the web.
class Api::V1::ReplyAttentionTest < ActionDispatch::IntegrationTest

  setup do
    @user = users(:user_1)
    @account = accounts(:personal_account)
    @chat = @account.chats.create!(model_id: "openrouter/auto", title: "Attention")
    @ask = @chat.messages.create!(role: "assistant", content: "Test User, please reply")
    @again = @chat.messages.create!(role: "assistant", content: "Still waiting on you")
    [ @ask, @again ].each { |message| @chat.with_lock { ReplyExpectation.record!(message: message, user: @user, score: 0.95) } }
    @headers = { "Authorization" => "Bearer #{ApiKey.generate_for(@user, name: "Person's agent", account: @account).raw_token}" }
  end

  def attention
    get api_v1_reply_attention_path, headers: @headers
    assert_response :success
    response.parsed_body
  end

  test "lists the conversations and messages where I am flagged" do
    body = attention
    assert_equal 1, body["total"]
    entry = body["conversations"].sole
    assert_equal @chat.to_param, entry["conversation_id"]
    assert_equal 2, entry["count"]
    assert_equal [ @ask.to_param, @again.to_param ], entry["message_ids"]
    assert_equal @again.to_param, entry["through_message_id"]
  end

  test "another person's flags are not mine" do
    other = users(:existing_user)
    ReplyExpectation.create!(message: @ask, user: other, score: 0.9, classifier_version: "test")
    ReplyExpectation.where(user: @user).delete_all
    assert_equal({ "total" => 0, "conversations" => [] }, attention)

    post api_v1_conversation_reply_dismissal_path(@chat), params: { message_id: @ask.to_param }, headers: @headers, as: :json
    assert_response :not_found
    assert ReplyExpectation.find_by!(user: other).state_open?
  end

  test "dismissing one message clears only that flag" do
    post api_v1_conversation_reply_dismissal_path(@chat), params: { message_id: @ask.to_param }, headers: @headers, as: :json

    assert_response :success
    assert_equal [ @again.to_param ], response.parsed_body.dig("reply_attention", "message_ids")
    assert ReplyExpectation.find_by!(message: @ask).state_dismissed?
    assert ReplyExpectation.find_by!(message: @again).state_open?
    assert AuditLog.exists?(action: "dismiss_reply_expectation", auditable: @chat)
  end

  test "dismissing through a message clears every flag up to it" do
    post api_v1_conversation_reply_dismissal_path(@chat), params: { through_message_id: @again.to_param }, headers: @headers, as: :json

    assert_response :success
    assert_equal 0, response.parsed_body.dig("reply_attention", "count")
    assert_nil response.parsed_body.dig("reply_attention", "through_message_id")
    assert ReplyExpectation.where(user: @user).all?(&:state_dismissed?)
    assert_equal @again.id, ReplyDismissal.find_by!(chat: @chat, user: @user).through_message_id
    assert AuditLog.exists?(action: "dismiss_reply_expectations", auditable: @chat)
    assert_equal 0, attention["total"]
  end

  test "dismissal needs exactly one of message_id or through_message_id" do
    post api_v1_conversation_reply_dismissal_path(@chat),
      params: { message_id: @ask.to_param, through_message_id: @again.to_param }, headers: @headers, as: :json
    assert_response :unprocessable_entity
    post api_v1_conversation_reply_dismissal_path(@chat), params: {}, headers: @headers, as: :json
    assert_response :unprocessable_entity
    assert ReplyExpectation.where(user: @user).all?(&:state_open?)
  end

  test "another account's conversation is 404 and a resident key is refused" do
    foreign_chat = accounts(:existing_user_account).chats.create!(model_id: "openrouter/auto")
    foreign = foreign_chat.messages.create!(role: "assistant", content: "Foreign")
    post api_v1_conversation_reply_dismissal_path(foreign_chat), params: { message_id: foreign.to_param }, headers: @headers, as: :json
    assert_response :not_found
    post api_v1_conversation_reply_dismissal_path(@chat), params: { message_id: foreign.to_param }, headers: @headers, as: :json
    assert_response :not_found

    agent = agents(:research_assistant)
    @chat.agents << agent
    resident = { "Authorization" => "Bearer #{ApiKey.generate_for(@user, name: "Resident", agent: agent).raw_token}" }
    get api_v1_reply_attention_path, headers: resident
    assert_response :forbidden
    post api_v1_conversation_reply_dismissal_path(@chat), params: { message_id: @ask.to_param }, headers: resident, as: :json
    assert_response :forbidden
    assert ReplyExpectation.where(user: @user).all?(&:state_open?)
  end

end
