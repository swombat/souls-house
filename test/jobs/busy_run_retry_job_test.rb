require "test_helper"

class BusyRunRetryJobTest < ActiveJob::TestCase

  setup do
    @user = users(:user_1)
    @account = @user.personal_account
    @account.update!(use_system_ai_credentials: false, openrouter_api_key: "test-only-router")
    @resident = @account.agents.create!(name: "Claude", system_prompt: "Test", runtime: "external")
    @sibling = @account.agents.create!(name: "Mira", system_prompt: "Test", runtime: "external")
    @chat = @account.chats.new(title: "Last message not picked", manual_responses: true)
    @chat.agents = [ @resident, @sibling ]
    @chat.save!
  end

  test "a tap answered already_running is held as a wake from the person who tapped, and released" do
    @chat.messages.create!(role: "user", user: @user, content: "Claude?")
    busy = busy_run(requested_by_user: @user)
    assert_enqueued_with(job: BusyRunRetryJob, args: [ busy.id ])

    AgentRuntimeInteraction.stub :live_activity_enabled?, true do
      assert_difference -> { AgentRuntimeInteraction.count }, 1 do
        perform_enqueued_jobs(only: PendingWakeJob) { BusyRunRetryJob.perform_now(busy.id) }
      end
    end
    wake = PendingWake.order(:id).last
    assert wake.released_at
    assert_equal [ [ "trigger", @user.id ] ], wake.sources.pluck(:kind, :user_id)
    assert wake.released_interaction.claim_dispatch!, "the released run claims on the person's standing"
  end

  test "a mention withdrawn before the retry does not wake the resident" do
    message = @chat.messages.create!(role: "user", user: @user, content: "@Claude look")
    busy = busy_run(message_dispatch: MessageDispatch.accept!(message: message, target_agent_ids: [ @resident.id ]))
    message.discard!

    AgentRuntimeInteraction.stub :live_activity_enabled?, true do
      assert_no_difference -> { AgentRuntimeInteraction.count } do
        perform_enqueued_jobs(only: PendingWakeJob) { BusyRunRetryJob.perform_now(busy.id) }
      end
    end
    assert_equal "sources_withdrawn", PendingWake.order(:id).last.drop_reason
  end

  test "a mention withdrawn after the retry run is reserved is refused at claim" do
    message = @chat.messages.create!(role: "user", user: @user, content: "@Claude look")
    busy = busy_run(message_dispatch: MessageDispatch.accept!(message: message, target_agent_ids: [ @resident.id ]))

    AgentRuntimeInteraction.stub :live_activity_enabled?, true do
      perform_enqueued_jobs(only: PendingWakeJob) { BusyRunRetryJob.perform_now(busy.id) }
    end
    retry_run = PendingWake.order(:id).last.released_interaction
    assert retry_run
    message.discard!
    refute retry_run.claim_dispatch!
    assert_equal "cancelled", retry_run.reload.execution_state
  end

  test "a later run that failed before reading anything does not consume the request" do
    @chat.messages.create!(role: "user", user: @user, content: "Claude?")
    busy = busy_run(requested_by_user: @user)
    later = AgentRuntimeInteraction.reserve!(agent: @resident, chat: @chat, wake_source_kinds: [ "peer" ])
    later.finish_execution!("failed")

    AgentRuntimeInteraction.stub :live_activity_enabled?, true do
      assert_difference -> { AgentRuntimeInteraction.count }, 1 do
        perform_enqueued_jobs(only: PendingWakeJob) { BusyRunRetryJob.perform_now(busy.id) }
      end
    end
  end

  test "a run that reached the resident and read the message makes the retry nothing new" do
    message = @chat.messages.create!(role: "user", user: @user, content: "Claude?")
    busy = busy_run(requested_by_user: @user)
    read = AgentRuntimeInteraction.reserve!(agent: @resident, chat: @chat, wake_source_kinds: [ "peer" ])
    read.update_columns(transport_status: 200, runtime_status: "ok", last_included_message_id: message.id)
    read.finish_execution!("completed")

    AgentRuntimeInteraction.stub :live_activity_enabled?, true do
      assert_no_difference -> { AgentRuntimeInteraction.count } do
        perform_enqueued_jobs(only: PendingWakeJob) { BusyRunRetryJob.perform_now(busy.id) }
      end
    end
    assert_equal "nothing_new", PendingWake.order(:id).last.drop_reason
  end

  test "a resident's handoff or a commitment is left to its own retry" do
    peer = nil
    assert_no_enqueued_jobs(only: BusyRunRetryJob) { peer = busy_run(kinds: [ "peer" ]) }
    refute BusyRunRetryJob.retry?(peer)

    human = busy_run(requested_by_user: @user)
    Commitment.stub :exists?, true do
      refute BusyRunRetryJob.retry?(human)
    end
  end

  test "gives up after repeated busy answers" do
    @chat.messages.create!(role: "user", user: @user, content: "Claude?")
    runs = Array.new(BusyRunRetryJob::MAX_ATTEMPTS + 1) { busy_run(requested_by_user: @user) }
    assert_no_difference -> { PendingWake.count } do
      BusyRunRetryJob.perform_now(runs.last.id)
    end
  end

  private

  def busy_run(kinds: [ "human" ], **options)
    run = AgentRuntimeInteraction.reserve!(agent: @resident, chat: @chat, wake_source_kinds: kinds, **options)
    run.update_columns(transport_status: 409, runtime_status: "already_running")
    run.finish_execution!("busy")
    run
  end

end
