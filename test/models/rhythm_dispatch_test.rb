require "test_helper"

class RhythmDispatchTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:research_assistant)
    @rhythm = Rhythm.create!(
      account: @agent.account, creator: users(:user_1), title: "Round",
      opening: "Please reflect together.", cadence: "daily", time_of_day: "09:00", timezone: "UTC",
      agents: [ @agent, agents(:code_reviewer) ]
    )
    @dispatch = @rhythm.fire!(manual: true, request_key: "round").occurrence.message_dispatch
  end

  test "rhythm dispatch reserves a linked resident round only once" do
    assert @dispatch.rhythm?
    assert @dispatch.from_message?
    assert_enqueued_jobs 1, only: ManualAgentResponseJob do
      2.times { MessageDispatchJob.perform_now(@dispatch) }
    end
    run = @dispatch.reload.runtime_interaction
    assert_equal @dispatch, run.message_dispatch
    assert_equal @dispatch.target_agent_ids.drop(1), run.response_chain_agent_ids
    assert run.claim_dispatch!
    assert_not run.claim_dispatch!
  end

  test "expired rhythm wake is recorded and not redriven" do
    travel MessageDispatch::EXPIRY + 1.minute do
      assert_no_enqueued_jobs { MessageDispatchSweepJob.perform_now }
      assert_equal "expired", @dispatch.reload.status
      assert_equal "not_started_in_time", @dispatch.reason
    end
  end

  test "discarding the opening cancels its pending rhythm wake" do
    @dispatch.message.discard_as_author!
    assert_equal "cancelled", @dispatch.reload.status
    assert_equal "discarded", @dispatch.reason
  end

end
