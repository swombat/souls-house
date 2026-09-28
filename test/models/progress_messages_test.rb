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
    assert_not middle.reload.progress_break_after?
    middle.destroy!
    assert first.reload.progress_break_after?
  end

  test "groupable posts retain ordinary response-chain behaviour without Telegram pushes" do
    @run.update!(response_chain_agent_ids: [ agents(:code_reviewer).id ])
    assert_no_enqueued_jobs(only: TelegramNotificationJob) do
      assert_enqueued_jobs 1, only: AllAgentsResponseJob do
        progress("Starting")
      end
    end
  end

  test "metadata and deletion still work after the linked run is removed" do
    first = progress("Kept speech")
    following = @chat.messages.create!(role: "user", user: users(:confirmed_user), content: "Following")
    @run.destroy!
    assert_nil first.reload.runtime_interaction_id
    first.update!(moderation_scores: { "test" => 0.1 })
    following.destroy!
    assert_not first.reload.progress_break_after?
    assert first.update(content: "Rewritten")
    assert_equal "Rewritten", first.reload.content
  end

  test "deleting a message does not validate or mark an ordinary predecessor" do
    previous = @chat.messages.create!(role: "user", user: users(:confirmed_user), content: "Historical")
    following = @chat.messages.create!(role: "user", user: users(:confirmed_user), content: "Following")
    previous.update_columns(content: nil)
    following.destroy!
    assert_not previous.reload.progress_break_after?
  end

  test "deleting a late arrival marks the chronological predecessor" do
    first = progress("First")
    first.update_column(:created_at, 2.minutes.ago)
    last = progress("Last")
    late = @chat.messages.create!(role: "user", user: users(:confirmed_user), content: "Late", created_at: 1.minute.ago)
    late.destroy!
    assert first.reload.progress_break_after?
    assert_not last.reload.progress_break_after?
  end

  private

  def progress(content)
    @chat.messages.create!(role: "assistant", agent: @agent, runtime_interaction: @run,
      content: content)
  end

end
