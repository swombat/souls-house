require "test_helper"

class ProgressMessagesTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:research_assistant)
    @chat = @agent.account.chats.create!(title: "Progress", manual_responses: true, agents: [ @agent ], model_id: "openrouter/auto")
    @run = @chat.agent_runtime_interactions.create!(agent: @agent, trigger_kind: "conversation",
      started_at: Time.current, run_id: SecureRandom.uuid, execution_state: "running",
      execution_deadline_at: 10.minutes.from_now)
  end

  test "deleting an intervening message retains the break even before the continuation arrives" do
    first = progress("First")
    interruption = @chat.messages.create!(role: "user", user: users(:confirmed_user), content: "Wait")
    interruption.destroy!
    assert first.reload.progress_break_after?
    last = progress("Next")
    assert_not last.progress_break_after?
    last.destroy!
    assert first.reload.progress_break_after?
  end

  test "deleting multiple intervening messages propagates the boundary" do
    first = progress("First")
    middle = @chat.messages.create!(role: "system", content: "Middle")
    last = @chat.messages.create!(role: "system", content: "Last")
    last.destroy!
    assert middle.reload.progress_break_after?
    middle.destroy!
    assert first.reload.progress_break_after?
  end

  test "completion queues one coalesced notification with the last authored message" do
    @agent.update!(telegram_bot_token: "test-token", telegram_bot_username: "test_bot")
    subscription = @agent.telegram_subscriptions.create!(user: users(:confirmed_user), telegram_chat_id: 12345)
    @run.update!(response_chain_agent_ids: [ agents(:code_reviewer).id ])
    progress("Starting")
    last = progress("Live and checked")
    assert_enqueued_jobs 1, only: ProgressCompletionJob do
      @run.finish_execution!("completed")
    end
    assert_no_enqueued_jobs(only: AllAgentsResponseJob) do
      assert_enqueued_with(job: TelegramNotificationJob, args: [ subscription, last, @chat ]) do
        ProgressCompletionJob.perform_now(@run)
      end
    end
    assert_no_enqueued_jobs(only: TelegramNotificationJob) { ProgressCompletionJob.perform_now(@run) }
    assert_equal "Wake ended", last.reload.progress_status
  end

  test "failed and lost runs do not imply task success or stay in progress" do
    message = progress("Checking")
    @run.update!(execution_deadline_at: 1.second.ago)
    assert_equal "Status unknown", message.reload.progress_status
    @run.finish_execution!("failed")
    assert_equal "Failed", message.reload.progress_status
  end

  test "ending a run without progress does not queue a summary" do
    assert_no_enqueued_jobs(only: ProgressCompletionJob) { @run.finish_execution!("completed") }
  end

  test "agent only rooms keep their notification privacy" do
    @chat.update!(title: "[AGENT-ONLY] Quiet work")
    @agent.update!(telegram_bot_token: "test-token", telegram_bot_username: "test_bot")
    @agent.telegram_subscriptions.create!(user: users(:confirmed_user), telegram_chat_id: 12345)
    progress("Private room update")
    @run.finish_execution!("completed")
    assert_no_enqueued_jobs(only: TelegramNotificationJob) { ProgressCompletionJob.perform_now(@run) }
  end

  private

  def progress(content)
    @chat.messages.create!(role: "assistant", agent: @agent, runtime_interaction: @run,
      progress_message: true, content: content)
  end

end
