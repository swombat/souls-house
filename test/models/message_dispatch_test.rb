require "test_helper"

# #94 B, step 4b-ii: a human message's wake is durable from acceptance, and
# deduplicated at the runtime interaction it reserves. These count durable
# effects (dispatches, interactions, successful claims), not queue jobs.
class MessageDispatchTest < ActiveSupport::TestCase

  include ActiveJob::TestHelper

  setup do
    @user = users(:user_1)
    @first = agents(:research_assistant)
    @second = agents(:code_reviewer)
    @chat = @first.account.chats.create!(title: "Dispatch", manual_responses: true, agents: [ @first, @second ])
    @message = Messages::PostFromHuman.new(chat: @chat, user: @user, content: "@Research Assistant then @Code Reviewer").call.message
    @dispatch = @message.message_dispatch
  end

  test "acceptance captures the targets in mention order and reserves one linked, capped run" do
    assert_equal [ @first.id, @second.id ], @dispatch.target_agent_ids

    assert_enqueued_jobs 1, only: ManualAgentResponseJob do
      MessageDispatchJob.perform_now(@dispatch)
    end
    run = @dispatch.reload.runtime_interaction
    assert_equal [ "reserved", @first, @dispatch, [ @second.id ] ],
                 [ @dispatch.status, run.agent, run.message_dispatch, run.response_chain_agent_ids ]
    assert run.execution_deadline_at <= @dispatch.expires_at
  end

  test "duplicate dispatch deliveries, even after the run completes, reserve nothing more" do
    MessageDispatchJob.perform_now(@dispatch)
    run = @dispatch.reload.runtime_interaction
    assert run.claim_dispatch!
    run.finish_execution!("completed")

    assert_no_difference "AgentRuntimeInteraction.count" do
      3.times { MessageDispatchJob.perform_now(@dispatch) }
    end
  end

  test "duplicate runtime deliveries after completion make no second claim" do
    MessageDispatchJob.perform_now(@dispatch)
    run = @dispatch.reload.runtime_interaction
    claims = [ run.claim_dispatch! ]
    run.finish_execution!("completed")
    claims << run.reload.claim_dispatch! << run.reload.claim_dispatch!

    assert_equal [ true, false, false ], claims
  end

  test "a reservation made late cannot start after the request expires" do
    travel 9.minutes + 59.seconds do
      MessageDispatchJob.perform_now(@dispatch)
    end
    run = @dispatch.reload.runtime_interaction
    assert_equal @dispatch.expires_at.to_i, run.execution_deadline_at.to_i

    travel 10.minutes + 1.second do
      assert_not run.reload.claim_dispatch!
      assert_equal "cancelled", run.reload.execution_state
    end
  end

  test "an unreserved request past its expiry is recorded as expired, by the job or the sweeper" do
    travel 11.minutes do
      assert_no_difference "AgentRuntimeInteraction.count" do
        MessageDispatchSweepJob.perform_now
      end
      assert_equal [ "expired", "not_started_in_time" ], @dispatch.reload.values_at(:status, :reason)
      assert @dispatch.settled_at
    end
  end

  test "a lost dispatch enqueue is re-driven by the sweeper and reserves exactly one run" do
    travel 31.seconds do
      assert_enqueued_jobs 1, only: MessageDispatchJob do
        MessageDispatchSweepJob.perform_now
      end
      assert_difference "AgentRuntimeInteraction.count", 1 do
        2.times { MessageDispatchJob.perform_now(@dispatch) }
      end
    end
  end

  test "a lost runtime enqueue after reservation is re-driven and claimed once" do
    MessageDispatchJob.perform_now(@dispatch)
    run = @dispatch.reload.runtime_interaction
    clear_enqueued_jobs

    travel 31.seconds do
      assert_enqueued_with(job: ManualAgentResponseJob, args: [ @chat, @first, { runtime_interaction_id: run.id } ]) do
        MessageDispatchSweepJob.perform_now
      end
      assert_equal [ true, false ], [ run.reload.claim_dispatch!, run.reload.claim_dispatch! ]
    end
  end

  test "an unknown runtime outcome is never re-invoked" do
    MessageDispatchJob.perform_now(@dispatch)
    run = @dispatch.reload.runtime_interaction
    run.claim_dispatch!
    run.finish_execution!("outcome_unknown")
    clear_enqueued_jobs

    travel 31.seconds do
      MessageDispatchSweepJob.perform_now
    end
    assert_no_enqueued_jobs only: [ ManualAgentResponseJob, AllAgentsResponseJob ]
  end

  test "an edit while pending cancels the request; after reservation it neither retracts nor retargets" do
    assert @message.update_as_author(content: "@Code Reviewer only now")
    assert_equal [ "cancelled", "edited" ], @dispatch.reload.values_at(:status, :reason)
    assert_no_difference("AgentRuntimeInteraction.count") { MessageDispatchJob.perform_now(@dispatch) }

    other = post("@Research Assistant and @Code Reviewer again")
    MessageDispatchJob.perform_now(other.message_dispatch)
    assert other.update_as_author(content: "@Code Reviewer instead")
    dispatch = other.message_dispatch.reload
    assert_equal [ "reserved", [ @first.id, @second.id ] ], [ dispatch.status, dispatch.target_agent_ids ]
    assert_equal @first, dispatch.runtime_interaction.agent
  end

  test "a discard cancels pending work, and reserved work its claim has not yet won" do
    @message.discard_as_author!
    assert_equal [ "cancelled", "discarded" ], @dispatch.reload.values_at(:status, :reason)

    other = post("@Research Assistant please")
    MessageDispatchJob.perform_now(other.message_dispatch)
    run = other.message_dispatch.reload.runtime_interaction
    other.discard_as_author!
    assert_equal "cancelled", run.reload.execution_state
    assert_not run.claim_dispatch!
    assert_nil run.reload.dispatch_claimed_at
  end

  test "a discard after the claim won cannot recall the run, but stops the chain" do
    MessageDispatchJob.perform_now(@dispatch)
    run = @dispatch.reload.runtime_interaction
    assert run.claim_dispatch!
    @message.discard_as_author!

    assert_equal "preparing", run.reload.execution_state
    run.finish_execution!("completed")
    assert_not run.reload.response_chain_ready?
    assert_no_difference "AgentRuntimeInteraction.count" do
      AllAgentsResponseJob.perform_now(@chat, [ @second.id ], after_interaction_id: run.id)
    end
  end

  test "losing membership while queued stops the claim and records why" do
    MessageDispatchJob.perform_now(@dispatch)
    run = @dispatch.reload.runtime_interaction
    memberships(:daniel_personal).update_columns(confirmed_at: nil)

    assert_not run.claim_dispatch!
    assert_equal [ "cancelled", "author_not_member" ], @dispatch.reload.values_at(:status, :reason)
    assert_equal "cancelled", run.reload.execution_state
  end

  test "a disabled account stops the claim too" do
    MessageDispatchJob.perform_now(@dispatch)
    @chat.account.update_columns(disabled_at: Time.current)

    assert_not @dispatch.reload.runtime_interaction.claim_dispatch!
    assert_equal "author_not_member", @dispatch.reload.reason
  end

  test "turning live activity off after acceptance stops new reservations and claims" do
    other = post("@Code Reviewer hello")
    MessageDispatchJob.perform_now(@dispatch)
    run = @dispatch.reload.runtime_interaction
    with_live_activity_off do
      MessageDispatchJob.perform_now(other.message_dispatch)
      assert_not run.claim_dispatch!
    end

    assert_equal [ "cancelled", "live_activity_disabled" ], other.message_dispatch.reload.values_at(:status, :reason)
    assert_equal "cancelled", run.reload.execution_state
  end

  test "the chain carries the dispatch, and a lost continuation is recovered while the first run is still active" do
    MessageDispatchJob.perform_now(@dispatch)
    run = @dispatch.reload.runtime_interaction
    run.claim_dispatch!
    run.activity_configuration!
    AllAgentsResponseJob.stub(:perform_later, nil) do
      @chat.messages.create!(agent: @first, role: "assistant", content: "Linked reply", runtime_interaction: run)
    end
    assert_nil run.reload.finished_at
    assert run.response_chain_ready?

    travel 31.seconds do
      assert_enqueued_with(job: AllAgentsResponseJob, args: [ @chat, [ @second.id ], { after_interaction_id: run.id } ]) do
        MessageDispatchSweepJob.perform_now
      end
      assert_difference "AgentRuntimeInteraction.count", 1 do
        2.times { AllAgentsResponseJob.perform_now(@chat, [ @second.id ], after_interaction_id: run.id) }
      end
    end
    successor = @dispatch.runtime_interactions.order(:id).last
    assert_equal [ @second, @dispatch ], [ successor.agent, successor.message_dispatch ]
  end

  test "the sweeper never touches chains no dispatch started" do
    unrelated = AgentRuntimeInteraction.reserve!(agent: @first, chat: @chat, response_chain_agent_ids: [ @second.id ])
    AllAgentsResponseJob.stub(:perform_later, nil) { unrelated.finish_execution!("completed") }
    @dispatch.update_columns(status: "cancelled")
    clear_enqueued_jobs

    travel 31.seconds do
      MessageDispatchSweepJob.perform_now
    end
    assert_no_enqueued_jobs
  end

  test "a cancelled request never advances its chain" do
    MessageDispatchJob.perform_now(@dispatch)
    run = @dispatch.reload.runtime_interaction
    run.claim_dispatch!
    @dispatch.update_columns(status: "cancelled", reason: "discarded")

    assert_no_enqueued_jobs only: AllAgentsResponseJob do
      run.finish_execution!("completed")
    end
    assert_not run.reload.response_chain_ready?
  end

  test "a run cancelled before its claim, by its deadline, does not advance its chain" do
    MessageDispatchJob.perform_now(@dispatch)
    run = @dispatch.reload.runtime_interaction
    clear_enqueued_jobs

    travel_to run.execution_deadline_at + 1.second do
      assert_no_enqueued_jobs only: AllAgentsResponseJob do
        assert_not run.claim_dispatch!
      end
      assert_equal "cancelled", run.reload.execution_state
      assert_not run.response_chain_ready?
      assert_no_enqueued_jobs only: AllAgentsResponseJob do
        MessageDispatchSweepJob.perform_now
      end
    end
  end

  private

  def post(content)
    Messages::PostFromHuman.new(chat: @chat, user: @user, content: content).call.message
  end

  def with_live_activity_off
    previous = ENV["SOULSHOUSE_LIVE_ACTIVITY"]
    ENV["SOULSHOUSE_LIVE_ACTIVITY"] = "0"
    yield
  ensure
    ENV["SOULSHOUSE_LIVE_ACTIVITY"] = previous
  end

end
