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

  test "ordinary posts carry grouping identity without opting in or changing delivery" do
    assert_no_enqueued_jobs(only: [ TelegramNotificationJob, ManualAgentResponseJob ]) do
      assert_enqueued_jobs 1, only: AllAgentsResponseJob do
        post_message("Checking @Code Reviewer")
      end
      assert_response :created
      first = response.parsed_body["message"]
      post_message("Checked")
      assert_response :created
      second = response.parsed_body["message"]
      assert_not_equal first["id"], second["id"]
      assert_equal @run.id, first["runtime_interaction_id"]
      assert_equal @run.id, second["runtime_interaction_id"]
      assert_not second["progress_message"]
      assert_equal "Checking @Code Reviewer", @chat.messages.first.content
    end
  end

  test "legacy progress parameter no longer changes ordinary posting behaviour" do
    assert_enqueued_jobs 1, only: AllAgentsResponseJob do
      post_message("Legacy caller", progress: true)
    end
    assert_response :created
    assert_not response.parsed_body["message"]["progress_message"]
  end

  test "ordinary messages retain attachments and editing" do
    post_message("", files: [ fixture_file_upload("test.txt", "text/plain") ])
    assert_response :created
    assert @chat.messages.last.attachments.attached?
    post_message("Published")
    assert_response :created
    assert @chat.messages.last.update(content: "Rewritten")
  end

  test "run linkage remains scoped to resident and room" do
    post_message("Wrong run", runtime_run_id: SecureRandom.uuid)
    assert_response :not_found
    @run.update!(agent: agents(:code_reviewer))
    post_message("Other resident")
    assert_response :not_found
    assert_empty @chat.messages
  end

  private

  def post_message(content, **options)
    post api_v1_conversation_messages_url(@chat),
      params: { content: content, runtime_run_id: @run.run_id }.merge(options),
      headers: { "Authorization" => "Bearer #{@token}" }
  end

end
