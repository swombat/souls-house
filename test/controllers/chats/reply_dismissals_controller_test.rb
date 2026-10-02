require "test_helper"

class Chats::ReplyDismissalsControllerTest < ActionDispatch::IntegrationTest

  setup do
    @user = users(:user_1)
    @account = accounts(:personal_account)
    @chat = @account.chats.create!(title: "Attention")
    @ask = @chat.messages.create!(role: "assistant", content: "Test User, please reply")
    @chat.with_lock { ReplyExpectation.record!(message: @ask, user: @user, score: 0.95) }
    post login_path, params: { email_address: @user.email_address, password: "password123" }
  end

  test "viewing a chat preserves request and exposes personal shared counts" do
    get account_chat_path(@account, @chat)
    assert_response :success
    assert_equal 1, inertia_shared_props.fetch("reply_attention").fetch("total")
    assert ReplyExpectation.find_by!(message: @ask).state_open?
  end

  test "dismiss uses visible message cutoff and cannot dismiss newer requests" do
    newer = @chat.messages.create!(role: "assistant", content: "Another question")
    @chat.with_lock { ReplyExpectation.record!(message: newer, user: @user, score: 0.95) }
    post account_chat_reply_dismissal_path(@account, @chat), params: { through_message_id: @ask.to_param }
    assert_response :see_other
    assert ReplyExpectation.find_by!(message: @ask).state_dismissed?
    assert ReplyExpectation.find_by!(message: newer).state_open?
  end

  test "sidebar dismissal returns to the referring page" do
    post account_chat_reply_dismissal_path(@account, @chat),
      params: { through_message_id: @ask.to_param },
      headers: { "HTTP_REFERER" => account_chats_url(@account) }
    assert_redirected_to account_chats_url(@account)
    assert ReplyExpectation.find_by!(message: @ask).state_dismissed?
  end

  test "dismissal never redirects to another host" do
    post account_chat_reply_dismissal_path(@account, @chat),
      params: { through_message_id: @ask.to_param },
      headers: { "HTTP_REFERER" => "https://untrusted.example/" }
    assert_redirected_to account_chat_path(@account, @chat)
  end

  test "requires own membership and source from this chat" do
    other = accounts(:existing_user_account).chats.create!(title: "Other")
    post account_chat_reply_dismissal_path(other.account, other), params: { through_message_id: @ask.to_param }
    assert_response :not_found
    other_message = other.messages.create!(role: "assistant", content: "Unrelated")
    post account_chat_reply_dismissal_path(@account, @chat), params: { through_message_id: other_message.to_param }
    assert_response :not_found
  end

end
