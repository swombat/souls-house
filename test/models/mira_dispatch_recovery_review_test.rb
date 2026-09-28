require_relative "message_dispatch_test"

class MessageDispatchTest
  test "review sweeper settles an expired reservation without a delivered job" do
    MessageDispatchJob.perform_now(@dispatch)
    run = @dispatch.reload.runtime_interaction
    clear_enqueued_jobs
    travel_to run.execution_deadline_at + 1.minute do
      MessageDispatchSweepJob.perform_now
      assert_equal "cancelled", run.reload.execution_state
      assert_equal "cancelled", @dispatch.reload.as_app_json[:runs].first[:status]
    end
  end

  test "review sweeper records expiry even after an outage longer than six hours" do
    travel 7.hours do
      MessageDispatchSweepJob.perform_now
      assert_equal "expired", @dispatch.reload.status
    end
  end
end
