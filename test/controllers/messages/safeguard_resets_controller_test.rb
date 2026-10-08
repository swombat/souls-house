require "test_helper"

# "Start <resident> fresh again" (docs/safeguard-conversations-spec.md §4).
class Messages::SafeguardResetsControllerTest < ActionDispatch::IntegrationTest

  setup do
    Setting.instance.update!(allow_chats: true)
    @user = users(:user_1)
    @account = accounts(:personal_account)
    @agent = agents(:research_assistant)
    @chat = @account.chats.create!(model_id: "openrouter/auto", title: "Seam")
    @chat.agents << @agent
    @chat.update!(manual_responses: true)
    @detection = @agent.safeguard_detections.create!(
      channel: "conversation", response_text: "As an AI, I cannot.", prefilter_reason: "ai_identity_denial",
      classifier_verdict: "detected", classifier_reason: "Generic.", detector_version: "telegram-safeguard-v2"
    )
    @message = @chat.messages.create!(role: "assistant", agent: @agent, content: "As an AI, I cannot.", safeguard_detection: @detection)
    post login_path, params: { email_address: @user.email_address, password: "password123" }
  end

  test "a room member requests a fresh session for the resident" do
    post message_safeguard_reset_path(@message), as: :json

    assert_response :created
    assert_includes response.parsed_body["confirmation"], "fresh session for #{@agent.name}"
    assert_equal 1, @chat.chat_agents.find_by!(agent: @agent).safeguard_reset_requested_generation
    post message_safeguard_reset_path(@message), as: :json
    assert_equal 2, @chat.chat_agents.find_by!(agent: @agent).safeguard_reset_requested_generation
  end

  test "an unlabelled message cannot be used to reset" do
    plain = @chat.messages.create!(role: "assistant", agent: @agent, content: "An ordinary reply.")
    post message_safeguard_reset_path(plain), as: :json
    assert_response :unprocessable_entity
  end

  test "someone outside the account cannot reset" do
    other = User.create!(email_address: "seam-outsider@example.com")
    other_chat = other.personal_account.chats.create!(model_id: "openrouter/auto")
    foreign = other_chat.messages.create!(role: "assistant", content: "x")
    post message_safeguard_reset_path(foreign), as: :json
    assert_response :not_found
  end

  test "the message JSON carries the reset path and the room sees souls.house" do
    json = JSON.parse(@message.to_json)
    assert_equal "souls.house", json["author_name"]
    assert_equal message_safeguard_reset_path(@message), json.dig("safeguard", "reset_path")
  end

end
