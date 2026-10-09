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

  test "acceptance captures the targets in mention order and wakes every one at once, linked and capped" do
    assert_equal [ @first.id, @second.id ], @dispatch.target_agent_ids

    assert_enqueued_jobs 2, only: ManualAgentResponseJob do
      MessageDispatchJob.perform_now(@dispatch)
    end
    run = @dispatch.reload.runtime_interaction
    assert_equal [ "reserved", @first, @dispatch, [] ],
                 [ @dispatch.status, run.agent, run.message_dispatch, run.response_chain_agent_ids ]
    runs = @dispatch.runtime_interactions.order(:id).to_a
    assert_equal [ @first, @second ], runs.map(&:agent)
    runs.each do |each_run|
      assert_equal [], each_run.response_chain_agent_ids
      assert each_run.execution_deadline_at <= @dispatch.expires_at
    end
  end

  # A chain reserved before Ask all became concurrent (2026-10-07) still
  # finishes as it began. Tests of that path build one directly.
  def reserve_legacy_chain!
    @dispatch.update_columns(target_agent_ids: [ @first.id ])
    MessageDispatchJob.perform_now(@dispatch)
    run = @dispatch.reload.runtime_interaction
    run.update_columns(response_chain_agent_ids: [ @second.id ])
    run
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

  test "a lost dispatch enqueue is not re-driven: it stays pending, then is recorded expired" do
    travel 31.seconds do
      assert_no_enqueued_jobs { MessageDispatchSweepJob.perform_now }
      assert_equal "pending", @dispatch.reload.status
    end
    travel MessageDispatch::EXPIRY + 1.minute do
      assert_no_enqueued_jobs { MessageDispatchSweepJob.perform_now }
      assert_no_difference("AgentRuntimeInteraction.count") { MessageDispatchJob.perform_now(@dispatch) }
      assert_equal [ "expired", "not_started_in_time" ], @dispatch.reload.values_at(:status, :reason)
    end
  end

  test "a lost runtime enqueue after reservation is not re-driven; the unclaimed run lapses at its deadline" do
    MessageDispatchJob.perform_now(@dispatch)
    run = @dispatch.reload.runtime_interaction
    clear_enqueued_jobs

    travel 31.seconds do
      assert_no_enqueued_jobs { MessageDispatchSweepJob.perform_now }
    end
    travel MessageDispatch::EXPIRY + 1.minute do
      # The lapsed run ending enqueues its pending-wake release (a no-op with
      # no wake held); nothing re-drives the dispatch itself.
      assert_no_enqueued_jobs(except: PendingWakeJob) { MessageDispatchSweepJob.perform_now }
      assert_equal "cancelled", run.reload.execution_state
      assert_not run.claim_dispatch!
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

  test "a discard after one claim won cannot recall that run, but cancels its unclaimed sibling" do
    MessageDispatchJob.perform_now(@dispatch)
    run = @dispatch.reload.runtime_interaction
    sibling = @dispatch.runtime_interactions.where.not(id: run.id).sole
    assert_equal @second, sibling.agent
    assert run.claim_dispatch!
    @message.discard_as_author!

    assert_equal "preparing", run.reload.execution_state
    assert_nil run.finished_at
    assert_equal "cancelled", sibling.reload.execution_state
    assert_not sibling.claim_dispatch!
    assert_nil sibling.reload.dispatch_claimed_at
  end

  test "a discard after the claim won cannot recall the run, but stops a legacy chain" do
    run = reserve_legacy_chain!
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

  test "a legacy chain carries the dispatch; a lost continuation is not recovered, and is recorded at the horizon" do
    run = reserve_legacy_chain!
    run.claim_dispatch!
    run.activity_configuration!
    AllAgentsResponseJob.stub(:perform_later, nil) do
      @chat.messages.create!(agent: @first, role: "assistant", content: "Linked reply", runtime_interaction: run)
    end
    assert_nil run.reload.finished_at
    assert run.response_chain_ready?

    travel 31.seconds do
      assert_no_enqueued_jobs { MessageDispatchSweepJob.perform_now }
      # The normal hand-on still works, once, and carries the dispatch.
      assert_difference "AgentRuntimeInteraction.count", 1 do
        2.times { AllAgentsResponseJob.perform_now(@chat, [ @second.id ], after_interaction_id: run.id) }
      end
    end
    successor = @dispatch.runtime_interactions.order(:id).last
    assert_equal [ @second, @dispatch ], [ successor.agent, successor.message_dispatch ]
  end

  test "past the recovery horizon a legacy chain's unstarted continuation is recorded, and nothing is started" do
    run = reserve_legacy_chain!
    run.claim_dispatch!
    AllAgentsResponseJob.stub(:perform_later, nil) { run.finish_execution!("completed") }
    clear_enqueued_jobs

    travel MessageDispatch::RECOVERY_HORIZON + 1.minute do
      assert_no_enqueued_jobs { MessageDispatchSweepJob.perform_now }
      assert_equal [ "expired", "continuation_not_started_in_time" ], [ @dispatch.reload.status, @dispatch.reason ]
    end
  end

  test "past the recovery horizon a finished dispatch stays reserved with its recovery closed" do
    MessageDispatchJob.perform_now(@dispatch)
    run = @dispatch.reload.runtime_interaction
    run.claim_dispatch!
    AllAgentsResponseJob.stub(:perform_later, nil) { run.finish_execution!("completed") }
    run.update_columns(response_chain_advanced_at: Time.current)

    travel MessageDispatch::RECOVERY_HORIZON + 1.minute do
      MessageDispatchSweepJob.perform_now
      assert_equal "reserved", @dispatch.reload.status
      assert @dispatch.settled_at?
      assert_no_difference -> { @dispatch.reload.updated_at } do
        MessageDispatchSweepJob.perform_now
      end
    end
  end

  test "a legacy continuation reserved before the horizon cannot be claimed after it; the running first run is untouched" do
    run = reserve_legacy_chain!
    assert run.claim_dispatch!
    AllAgentsResponseJob.stub(:perform_later, nil) do
      @chat.messages.create!(agent: @first, role: "assistant", content: "Linked reply", runtime_interaction: run)
    end
    assert_difference "AgentRuntimeInteraction.count", 1 do
      AllAgentsResponseJob.perform_now(@chat, [ @second.id ], after_interaction_id: run.id)
    end
    successor = @dispatch.runtime_interactions.order(:id).last
    assert_not_equal run, successor
    assert_equal @second, successor.agent

    travel MessageDispatch::RECOVERY_HORIZON + 1.minute do
      assert_not successor.claim_dispatch!
      assert_equal "cancelled", successor.reload.execution_state
      assert_equal "reserved", @dispatch.reload.status
      assert @dispatch.settled_at?
      assert_equal "preparing", run.reload.execution_state
      assert_nil run.finished_at
    end
  end

  test "one dispatch failing in the sweep does not stop the others" do
    other = Messages::PostFromHuman.new(chat: @chat, user: @user, content: "@Code Reviewer again").call.message.message_dispatch
    failing = @dispatch
    original = MessageDispatch.instance_method(:settle_lapsed!)
    MessageDispatch.define_method(:settle_lapsed!) do
      raise "row failure" if id == failing.id
      original.bind_call(self)
    end
    travel 11.minutes do
      MessageDispatchSweepJob.perform_now
    end
    assert_equal "expired", other.reload.status
  ensure
    MessageDispatch.define_method(:settle_lapsed!, original)
  end

  test "duplicate runtime job deliveries after completion reach the runtime once" do
    @first.update!(uuid: SecureRandom.uuid, endpoint_url: "https://agent.example.com", trigger_bearer_token: "synthetic",
                   health_state: "healthy", consecutive_health_failures: 0)
    MessageDispatchJob.perform_now(@dispatch)
    run = @dispatch.reload.runtime_interaction
    runtime_calls = 0
    sandbox = Object.new
    sandbox.define_singleton_method(:with_runtime) { |&_| runtime_calls += 1 }

    Agents::Sandbox.stub(:new, sandbox) do
      ManualAgentResponseJob.perform_now(@chat, @first, runtime_interaction_id: run.id)
      AllAgentsResponseJob.stub(:perform_later, nil) { run.reload.finish_execution!("completed") }
      2.times { ManualAgentResponseJob.perform_now(@chat, @first, runtime_interaction_id: run.id) }
    end
    assert_equal 1, runtime_calls
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


  # --- invoke variant (keyed-invoke extension) -------------------------------

  test "the variants hold in the model and in the database: a mention has its message, an invoke its key and digest" do
    now = Time.current
    base = { chat: @chat, user: @user, accepted_at: now, expires_at: now + 1.minute }
    assert_not MessageDispatch.new(base.merge(kind: "invoke", message: @message, client_invocation_id: "k-0000001", request_digest: "v1:x")).valid?
    assert_not MessageDispatch.new(base.merge(kind: "invoke", client_invocation_id: "k-0000001")).valid?
    assert_not MessageDispatch.new(base.merge(kind: "mention")).valid?
    assert_not MessageDispatch.new(base.merge(kind: "other", client_invocation_id: "k-0000001", request_digest: "v1:x")).valid?

    assert_raises(ActiveRecord::StatementInvalid) { @dispatch.update_columns(client_invocation_id: "k-0000001", request_digest: "v1:x") }
  end

  test "an invoke-all wakes everyone at once and is swept like a mention's, with no continuation owed" do
    @message.message_dispatch.update!(status: "cancelled", reason: "test", settled_at: Time.current)
    dispatch = MessageDispatch.invoke!(chat: @chat, user: @user, client_invocation_id: "invoke-00000001", agent: nil)
    runs = dispatch.runtime_interactions.order(:id).to_a
    assert_equal @chat.agents.order(:id).ids, runs.map(&:agent_id)
    assert runs.all? { |run| run.response_chain_agent_ids.empty? }
    runs.each do |run|
      run.claim_dispatch!
      run.finish_execution!("completed")
    end
    clear_enqueued_jobs

    travel MessageDispatch::RECOVERY_HORIZON + 1.minute do
      assert_no_enqueued_jobs { MessageDispatchSweepJob.perform_now }
      assert_equal "reserved", dispatch.reload.status
      assert dispatch.settled_at
    end
  end

  test "every run of an invoke-all carries the dispatch and is gated by it" do
    dispatch = MessageDispatch.invoke!(chat: @chat, user: @user, client_invocation_id: "invoke-00000001", agent: nil)
    run = dispatch.runtime_interaction
    run.claim_dispatch!
    run.finish_execution!("completed")
    successor = dispatch.runtime_interactions.order(:id).last
    assert_not_equal run, successor
    assert_equal dispatch, successor.message_dispatch

    memberships(:daniel_personal).update_columns(confirmed_at: nil)
    assert_not successor.claim_dispatch!
    assert_equal [ "cancelled", "author_not_member" ], dispatch.reload.values_at(:status, :reason)
  end

  test "an invoke that cannot reserve anything rolls back whole" do
    @first.update!(active: false)
    @second.update!(active: false)
    assert_no_difference [ "MessageDispatch.count", "AgentRuntimeInteraction.count" ] do
      assert_raises(Agent::RuntimeAvailability::Unavailable) do
        MessageDispatch.invoke!(chat: @chat, user: @user, client_invocation_id: "invoke-00000001", agent: nil)
      end
    end
  end

end
