require_relative "message_dispatch_test"

# Consultation BjAPDe (Daniel YPLPyY, Chris JDmlVj): no delayed recovery. A
# lost wake or chain step is re-driven within ten minutes of becoming due, or
# recorded as not started; the person asks again. Chains themselves may still
# run long, one link after another.
class MessageDispatchTest

  def finished_first_run
    MessageDispatchJob.perform_now(@dispatch)
    run = @dispatch.reload.runtime_interaction
    assert run.claim_dispatch!
    AllAgentsResponseJob.stub(:perform_later, nil) { run.finish_execution!("completed") }
    clear_enqueued_jobs
    run
  end

  test "window: a lost chain step is re-driven inside ten minutes of becoming due" do
    run = finished_first_run

    travel MessageDispatch::RECOVERY_WINDOW - 1.minute do
      assert_enqueued_with(job: AllAgentsResponseJob, args: [ @chat, [ @second.id ], { after_interaction_id: run.id } ]) do
        MessageDispatchSweepJob.perform_now
      end
      assert_equal "reserved", @dispatch.reload.status
    end
  end

  test "window: past ten minutes a lost chain step is recorded at once, and nothing starts" do
    run = finished_first_run

    travel MessageDispatch::RECOVERY_WINDOW + 1.minute do
      assert_no_enqueued_jobs only: AllAgentsResponseJob do
        MessageDispatchSweepJob.perform_now
      end
      assert_equal [ "expired", "continuation_not_started_in_time" ], @dispatch.reload.values_at(:status, :reason)
      assert_not run.reload.response_chain_ready?
      assert_no_difference "AgentRuntimeInteraction.count" do
        AllAgentsResponseJob.perform_now(@chat, [ @second.id ], after_interaction_id: run.id)
      end
    end
  end

  test "window: a late queue delivery of the normal advance cannot start a missed step either" do
    run = finished_first_run

    travel MessageDispatch::RECOVERY_WINDOW + 1.minute do
      assert_no_difference "AgentRuntimeInteraction.count" do
        AllAgentsResponseJob.perform_now(@chat, [ @second.id ], after_interaction_id: run.id)
      end
    end
  end

  test "window: a long first turn still hands on, because the window runs from when it finished" do
    MessageDispatchJob.perform_now(@dispatch)
    run = @dispatch.reload.runtime_interaction
    assert run.claim_dispatch!

    travel 45.minutes do
      AllAgentsResponseJob.stub(:perform_later, nil) { run.finish_execution!("completed") }
      assert run.reload.response_chain_ready?
      assert_difference "AgentRuntimeInteraction.count", 1 do
        AllAgentsResponseJob.perform_now(@chat, [ @second.id ], after_interaction_id: run.id)
      end
      assert_equal "reserved", @dispatch.reload.status
    end
  end

  test "window: the window runs from the linked reply when that came before the finish" do
    MessageDispatchJob.perform_now(@dispatch)
    run = @dispatch.reload.runtime_interaction
    assert run.claim_dispatch!
    AllAgentsResponseJob.stub(:perform_later, nil) do
      @chat.messages.create!(agent: @first, role: "assistant", content: "Linked reply", runtime_interaction: run)
    end
    clear_enqueued_jobs

    travel MessageDispatch::RECOVERY_WINDOW + 1.minute do
      assert_no_enqueued_jobs only: AllAgentsResponseJob do
        MessageDispatchSweepJob.perform_now
      end
      assert_equal "expired", @dispatch.reload.status
    end
  end

end
