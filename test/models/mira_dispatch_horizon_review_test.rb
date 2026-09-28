require_relative "message_dispatch_test"

class MessageDispatchTest

  test "review retry recovery cannot bypass the horizon before the sweeper arrives" do
    MessageDispatchJob.perform_now(@dispatch)
    run = @dispatch.reload.runtime_interaction
    assert run.claim_dispatch!
    AllAgentsResponseJob.stub(:perform_later, nil) { run.finish_execution!("completed") }
    clear_enqueued_jobs

    travel MessageDispatch::RECOVERY_HORIZON + 1.minute do
      assert_no_enqueued_jobs only: AllAgentsResponseJob do
        @dispatch.redrive!
      end
      assert_equal [ "expired", "continuation_not_started_in_time" ], @dispatch.reload.values_at(:status, :reason)
    end
  end

  test "review closed recovery does not reopen when a late linked reply appears" do
    MessageDispatchJob.perform_now(@dispatch)
    run = @dispatch.reload.runtime_interaction
    assert run.claim_dispatch!
    clear_enqueued_jobs

    travel MessageDispatch::RECOVERY_HORIZON + 1.minute do
      MessageDispatchSweepJob.perform_now
      assert @dispatch.reload.settled_at
      assert_no_enqueued_jobs only: AllAgentsResponseJob do
        @chat.messages.create!(agent: @first, role: "assistant", content: "Late linked reply", runtime_interaction: run)
      end
    end
  end

end
