require "test_helper"

# "Start <resident> fresh again" through a person's key (messages/safeguard_resets).
class Api::V1::SafeguardResetsControllerTest < ActionDispatch::IntegrationTest

  setup do
    Setting.instance.update!(allow_chats: true)
    @user = users(:user_1)
    @account = accounts(:personal_account)
    @agent = agents(:research_assistant)
    @chat = @account.chats.create!(model_id: "openrouter/auto", title: "Seam")
    @chat.agents << @agent
    @chat.update!(manual_responses: true)
    detection = @agent.safeguard_detections.create!(
      channel: "conversation", response_text: "As an AI, I cannot.", prefilter_reason: "ai_identity_denial",
      classifier_verdict: "detected", classifier_reason: "Generic.", detector_version: "telegram-safeguard-v2"
    )
    @message = @chat.messages.create!(role: "assistant", agent: @agent, content: "As an AI, I cannot.", safeguard_detection: detection)
    @headers = { "Authorization" => "Bearer #{ApiKey.generate_for(@user, name: "Person's agent", account: @account).raw_token}" }
  end

  def generation
    @chat.chat_agents.find_by!(agent: @agent).safeguard_reset_requested_generation
  end

  test "a member asks for a fresh session; repeats are harmless" do
    2.times do
      post api_v1_conversation_message_safeguard_reset_path(@chat, @message), headers: @headers, as: :json
      assert_response :created
      assert_includes response.parsed_body["confirmation"], "fresh session for #{@agent.name}"
    end
    assert_equal 2, generation
  end

  test "an unlabelled message or an archived room is refused" do
    plain = @chat.messages.create!(role: "assistant", agent: @agent, content: "An ordinary reply.")
    post api_v1_conversation_message_safeguard_reset_path(@chat, plain), headers: @headers, as: :json
    assert_response :unprocessable_entity

    @chat.archive!
    post api_v1_conversation_message_safeguard_reset_path(@chat, @message), headers: @headers, as: :json
    assert_response :unprocessable_entity
    assert_equal 0, generation
  end

  test "another account is 404 and a resident key is refused" do
    foreign_chat = accounts(:existing_user_account).chats.create!(model_id: "openrouter/auto")
    foreign = foreign_chat.messages.create!(role: "assistant", content: "x")
    post api_v1_conversation_message_safeguard_reset_path(foreign_chat, foreign), headers: @headers, as: :json
    assert_response :not_found

    resident = { "Authorization" => "Bearer #{ApiKey.generate_for(@user, name: "Resident", agent: @agent).raw_token}" }
    post api_v1_conversation_message_safeguard_reset_path(@chat, @message), headers: resident, as: :json
    assert_response :forbidden
    assert_equal 0, generation
  end

end
