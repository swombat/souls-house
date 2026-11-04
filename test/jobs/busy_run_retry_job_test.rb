require "test_helper"

class BusyRunRetryJobTest < ActiveJob::TestCase

  setup do
    @user = users(:user_1)
    @account = @user.personal_account
    @account.update!(use_system_ai_credentials: false, openrouter_api_key: "test-only-router")
    @resident = @account.agents.create!(name: "Claude", system_prompt: "Test", runtime: "external")
    @chat = @account.chats.new(title: "Last message not picked", manual_responses: true)
    @chat.agents = [ @resident ]
    @chat.save!
  end

  test "a person's run answered already_running is asked again, once" do
    busy = busy_run([ "human" ])
    assert_enqueued_with(job: BusyRunRetryJob, args: [ busy.id ])

    AgentRuntimeInteraction.stub :live_activity_enabled?, true do
      assert_difference -> { AgentRuntimeInteraction.count }, 1 do
        BusyRunRetryJob.perform_now(busy.id)
      end
      assert_no_difference -> { AgentRuntimeInteraction.count }, "the retry is superseded by its own run" do
        BusyRunRetryJob.perform_now(busy.id)
      end
    end
    retry_run = AgentRuntimeInteraction.order(:id).last
    assert_equal [ @resident.id, @chat.id, [ "human" ] ], [ retry_run.agent_id, retry_run.chat_id, retry_run.wake_source_kinds ]
  end

  test "a resident's handoff or a commitment is left to its own retry" do
    peer = nil
    assert_no_enqueued_jobs(only: BusyRunRetryJob) { peer = busy_run([ "peer" ]) }
    refute BusyRunRetryJob.retry?(peer)

    human = busy_run([ "human" ])
    Commitment.stub :exists?, true do
      refute BusyRunRetryJob.retry?(human)
    end
  end

  test "stands down while the resident is still responding, and when paused" do
    busy = busy_run([ "human" ])
    AgentRuntimeInteraction.stub :live_activity_enabled?, true do
      @resident.update!(paused: true)
      assert_no_difference -> { AgentRuntimeInteraction.count } do
        BusyRunRetryJob.perform_now(busy.id)
      end
    end
  end

  test "gives up after repeated busy answers" do
    runs = Array.new(BusyRunRetryJob::MAX_ATTEMPTS + 1) { busy_run([ "human" ]) }
    AgentRuntimeInteraction.stub :live_activity_enabled?, true do
      assert_no_difference -> { AgentRuntimeInteraction.count } do
        BusyRunRetryJob.perform_now(runs.last.id)
      end
    end
  end

  private

  def busy_run(kinds)
    run = AgentRuntimeInteraction.reserve!(agent: @resident, chat: @chat, wake_source_kinds: kinds)
    run.update_columns(transport_status: 409, runtime_status: "already_running")
    run.finish_execution!("busy")
    run
  end

end
