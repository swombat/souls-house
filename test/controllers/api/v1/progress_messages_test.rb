require "test_helper"

class Api::V1::ProgressMessagesTest < ActionDispatch::IntegrationTest

  setup do
    @agent = agents(:research_assistant)
    @user = users(:confirmed_user)
    @chat = @agent.account.chats.create!(title: "Progress", manual_responses: true, agents: [ @agent ], model_id: "openrouter/auto")
    @token = ApiKey.generate_for(@user, name: "Progress", agent: @agent).raw_token
    @run = @chat.agent_runtime_interactions.create!(agent: @agent, trigger_kind: "conversation",
      started_at: Time.current, run_id: SecureRandom.uuid, execution_state: "running",
      dispatch_claimed_at: Time.current, execution_deadline_at: 10.minutes.from_now,
      activity_token_expires_at: 20.minutes.from_now, response_chain_agent_ids: [ agents(:code_reviewer).id ])
  end

  test "progress posts are separate ordinary records without peer wakes or notifications" do
    assert_no_enqueued_jobs(only: [ AllAgentsResponseJob, TelegramNotificationJob, ManualAgentResponseJob ]) do
      post_progress("Checking @Code Reviewer")
      assert_response :created
      first = response.parsed_body["message"]
      post_progress("Checked")
      assert_response :created
      second = response.parsed_body["message"]
      assert_not_equal first["id"], second["id"]
      assert_equal @run.id, second["runtime_interaction_id"]
      assert_equal @run.run_id, second["progress_run_id"]
      assert_equal "In progress", second["progress_status"]
      assert second["progress_message"]
      assert_equal "Checking @Code Reviewer", @chat.messages.first.content
    end
  end

  test "ordinary post keeps its response chain behaviour and is not progress" do
    assert_enqueued_jobs 1, only: AllAgentsResponseJob do
      post_progress("Standalone", progress: false)
    end
    assert_response :created
    assert_not response.parsed_body["message"]["progress_message"]
  end

  test "progress requires a claimed live run owned by this resident and conversation" do
    post_progress("No run", runtime_run_id: nil)
    assert_response :unprocessable_entity
    post_progress("Wrong run", runtime_run_id: SecureRandom.uuid)
    assert_response :not_found
    @run.update!(agent: agents(:code_reviewer))
    post_progress("Other resident")
    assert_response :not_found
    @run.update!(agent: @agent, execution_deadline_at: 1.second.ago)
    post_progress("Expired")
    assert_response :unprocessable_entity
    @run.update!(execution_deadline_at: 10.minutes.from_now, finished_at: Time.current, execution_state: "completed")
    post_progress("Late")
    assert_response :unprocessable_entity
    assert_empty @chat.messages
  end

  test "human credentials cannot create progress posts" do
    @token = ApiKey.generate_for(@user, name: "Human", account: @chat.account).raw_token
    post_progress("No impersonation")
    assert_response :forbidden
    post_progress("No implicit run", runtime_run_id: nil)
    assert_response :unprocessable_entity
  end

  test "progress is text only and published content is immutable" do
    post_progress("", files: [ fixture_file_upload("test.txt", "text/plain") ])
    assert_response :unprocessable_entity
    post_progress("Published")
    assert_response :created
    assert_not @chat.messages.last.update(content: "Rewritten")
    assert_equal "Published", @chat.messages.last.reload.content
  end

  test "a run cannot publish progress into another room" do
    other = @agent.account.chats.create!(title: "Elsewhere", manual_responses: true, agents: [ @agent ], model_id: "openrouter/auto")
    original = @chat
    @chat = other
    post_progress("Wrong destination")
    assert_response :not_found
    assert_empty other.messages
    assert_empty original.messages
  end

  test "oversized progress is rejected rather than truncated" do
    assert_no_difference "Message.count" do
      post_progress("x" * 32_001)
    end
    assert_response :unprocessable_entity
    assert_includes response.parsed_body["errors"].join, "too long"
  end

  private

  def post_progress(content, **options)
    post api_v1_conversation_messages_url(@chat),
      params: { content: content, progress: true, runtime_run_id: @run.run_id }.merge(options),
      headers: { "Authorization" => "Bearer #{@token}" }
  end

end
