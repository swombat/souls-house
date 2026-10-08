require "test_helper"

class Chats::ModelSelectionsControllerTest < ActionDispatch::IntegrationTest

  setup do
    @user = users(:user_1)
    @account = @user.accounts.first
    @agent = agents(:research_assistant)
    @agent.update!(model_id: "anthropic/claude-opus-5.5", switchable_model_ids: [ "anthropic/claude-fable-5.1" ])
    @chat = @account.chats.new(model_id: "openrouter/auto", manual_responses: true)
    @chat.agent_ids = [ @agent.id ]
    @chat.save!
    sign_in @user
  end

  def seat = ChatAgent.find_by!(chat: @chat, agent: @agent)

  test "a person selects a model and returns to the default" do
    patch account_chat_model_selection_path(@account, @chat),
      params: { agent_id: @agent.to_param, model_id: "anthropic/claude-fable-5.1" }, as: :json

    assert_response :success
    assert_equal "Claude Fable 5.1", JSON.parse(response.body).dig("model_selection", "label")
    assert_equal "anthropic/claude-fable-5.1", seat.model_id

    patch account_chat_model_selection_path(@account, @chat), params: { agent_id: @agent.to_param, model_id: "default" }, as: :json
    assert_nil seat.model_id
    assert_equal 2, @chat.messages.where(role: "system").count
  end

  test "a model off the list is refused with the reason" do
    patch account_chat_model_selection_path(@account, @chat),
      params: { agent_id: @agent.to_param, model_id: "anthropic/claude-haiku-5.5" }, as: :json

    assert_response :unprocessable_entity
    assert_match(/not on Research Assistant's list/, JSON.parse(response.body)["error"])
  end

end
