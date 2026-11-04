require "test_helper"

class Api::V1::TelegramQuietReasonsControllerTest < ActionDispatch::IntegrationTest

  setup do
    @agent = agents(:research_assistant)
    @subscription = @agent.telegram_subscriptions.create!(user: users(:user_1), telegram_chat_id: 111)
    @key = ApiKey.generate_for(users(:confirmed_user), name: "Quiet", agent: @agent)
    @run = @agent.agent_runtime_interactions.create!(
      trigger_kind: "telegram", run_id: SecureRandom.uuid, started_at: Time.current,
      conversation_obfuscated_id: @subscription.to_param, provider_auth_mode: "api_key"
    )
  end

  test "an authenticated own live DM turn may declare quiet with or without reason" do
    post_quiet(reason: "No <extra> answer.\nAlready answered.")
    assert_response :success
    assert_equal "No <extra> answer.\nAlready answered.", @run.reload.quiet_reason
    assert @run.quiet_reason_at
    assert_no_difference "TelegramMessage.count" do
      post_quiet
      assert_response :success
      assert_equal "", @run.reload.quiet_reason
    end
  end

  test "finished turns foreign runs and wrong threads cannot declare quiet" do
    post_quiet(runtime_run_id: SecureRandom.uuid)
    assert_response :not_found
    other = @agent.telegram_subscriptions.create!(user: users(:confirmed_user), telegram_chat_id: 222)
    post "/api/v1/telegram_conversations/#{other.to_param}/quiet_reason",
      params: { runtime_run_id: @run.run_id }, headers: headers
    assert_response :not_found
    @run.update!(finished_at: Time.current)
    post_quiet(reason: "Too late")
    assert_response :unprocessable_entity
  end

  test "a sent reply prevents a quiet declaration" do
    @subscription.telegram_messages.create!(
      role: "assistant", text: "Reply", sent_at: Time.current,
      telegram_message_id: 1, agent_runtime_interaction: @run
    )
    post_quiet
    assert_response :unprocessable_entity
  end

  test "reason limit and groups are rejected" do
    post_quiet(reason: "x" * 501)
    assert_response :unprocessable_entity
    group = @agent.telegram_threads.create!(chat_kind: "group", telegram_chat_id: -123, allowed: true)
    post "/api/v1/telegram_conversations/#{group.to_param}/quiet_reason",
      params: { runtime_run_id: @run.run_id }, headers: headers
    assert_response :not_found
  end

  private

  def headers
    { "Authorization" => "Bearer #{@key.raw_token}" }
  end

  def post_quiet(**params)
    post "/api/v1/telegram_conversations/#{@subscription.to_param}/quiet_reason",
      params: { runtime_run_id: @run.run_id }.merge(params), headers: headers
  end

end
