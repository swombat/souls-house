require "test_helper"

class StalledThreadWakeTest < ActiveSupport::TestCase

  setup do
    @lume = agents(:research_assistant)
    @mira = agents(:code_reviewer)
    [ @lume, @mira ].each { |agent| make_runnable(agent) }
    @person = users(:user_1)
    @chat = @lume.account.chats.create!(title: "Quiet room", manual_responses: true, agents: [ @lume, @mira ])
    @chat.chat_agents.update_all(created_at: 1.day.ago)
    @lume.account.update!(stalled_sweep_enabled: true, resident_handoff_cap: 6)
    Setting.instance.update!(stalled_sweep_minutes: 10, stalled_sweep_wake: true)
    post(@person, "Please build it and get Mira to review.", at: 3.hours.ago)
    post(@mira, "Approved at abc123, merge once CI is green.", at: 2.hours.ago)
  end

  test "a resident judged to have a step is woken once, with a notice, carrying the sweep" do
    assert_enqueued_jobs(1, only: ManualAgentResponseJob) { sweep(lume: 0.9) }

    run = @chat.agent_runtime_interactions.sole
    assert_equal [ @lume, "queued" ], [ run.agent, run.execution_state ]
    sweep = run.stalled_thread_sweep
    assert_equal [ [ @lume.id ], [ @lume.id ] ], [ sweep.would_wake_agent_ids, sweep.woken_agent_ids ]
    assert_match "Stalled-thread check", @chat.messages.order(:id).last.content
    assert_match "grants no new permissions", sweep.nudge_text
  end

  test "shadow mode records the verdict and wakes nobody" do
    Setting.instance.update!(stalled_sweep_wake: false)
    assert_no_difference(-> { AgentRuntimeInteraction.count }) do
      assert_no_difference(-> { Message.count }) { sweep(lume: 0.9, wake: false) }
    end
    assert_equal "would_wake", StalledThreadSweep.sole.outcome
  end

  # The shared budget

  test "with a cap of one, two positives in one sweep wake only one" do
    @lume.account.update!(resident_handoff_cap: 1)
    sweep(lume: 0.95, mira: 0.9)
    assert_equal [ @lume ], @chat.agent_runtime_interactions.map(&:agent)
    assert_equal [ [ @mira.id, "loop_cap" ] ], StalledThreadSweep.sole.held.map { |h| h.values_at("agent_id", "reason") }
  end

  test "a sweeper wake uses the handoff budget: a later tag is capped" do
    @lume.account.update!(resident_handoff_cap: 1)
    sweep(lume: 0.9)
    tag = @chat.messages.create!(role: "assistant", agent: @lume, content: "Over to you.", handoff_recipient_ids: [ @mira.id ])
    assert_equal [ [ "blocked", "loop_cap" ] ], tag.handoffs.pluck(:status, :reason)
  end

  test "a tag uses the budget a sweeper wake would need" do
    @lume.account.update!(resident_handoff_cap: 1)
    tag = @chat.messages.create!(role: "assistant", agent: @mira, content: "Your turn.", handoff_recipient_ids: [ @lume.id ])
    tag.update_columns(created_at: 90.minutes.ago)
    assert_equal [ nil ], tag.handoffs.pluck(:reason), "the tag itself used the one slot"
    assert_no_difference(-> { AgentRuntimeInteraction.where.not(stalled_thread_sweep_id: nil).count }) { sweep(lume: 0.9) }
    assert_equal [ "loop_cap" ], StalledThreadSweep.sole.held.pluck("reason")
  end

  # The stop

  test "the same chain is not woken twice; the stop is told once and holds for everyone" do
    sweep(lume: 0.9)
    finish_runs
    post(@lume, "Still waiting on CI.", at: 1.second.from_now)
    assert_no_difference(-> { AgentRuntimeInteraction.count }) { sweep(lume: 0.9, mira: 0.9) }
    assert_equal 1, stop_notices
    assert_equal [ [ @lume.id, "already_woken_in_chain" ], [ @mira.id, "chain_stopped" ] ],
      StalledThreadSweep.order(:id).last.held.map { |h| h.values_at("agent_id", "reason") }

    post(@lume, "Hm.", at: 3.seconds.from_now)
    assert_no_difference(-> { AgentRuntimeInteraction.count }) { sweep(mira: 0.9) }
    assert_equal 1, stop_notices, "a stopped chain stays stopped, for a different resident too"

    post(@person, "Any news?", at: 5.seconds.from_now)
    post(@lume, "Looking.", at: 7.seconds.from_now)
    assert_difference(-> { AgentRuntimeInteraction.count }, 1) { sweep(lume: 0.9) }
  end

  test "two already-woken residents produce one stop notice" do
    sweep(lume: 0.9, mira: 0.85)
    finish_runs
    post(@lume, "Hm.", at: 1.second.from_now)
    sweep(lume: 0.9, mira: 0.9)
    assert_equal 1, stop_notices
  end

  # Gates read fresh

  test "waking switched off, or the account opted out, while Jev answers: nobody is woken" do
    flip = lambda do |state:, questions:|
      Setting.instance.update!(stalled_sweep_wake: false)
      answers(lume: 0.9).call(state: state, questions: questions)
    end
    assert_no_difference(-> { AgentRuntimeInteraction.count }) { sweeper(decide: flip).call }
    assert_equal [ "wake_off" ], StalledThreadSweep.sole.held.pluck("reason")

    Setting.instance.update!(stalled_sweep_wake: true)
    post(@lume, "Hm.", at: 1.second.from_now)
    opt_out = lambda do |state:, questions:|
      @lume.account.update!(stalled_sweep_enabled: false)
      answers(lume: 0.9).call(state: state, questions: questions)
    end
    assert_no_difference(-> { AgentRuntimeInteraction.count }) { sweeper(decide: opt_out).call }
    assert_equal [ "account_not_opted_in" ], StalledThreadSweep.order(:id).last.held.pluck("reason")
  end

  test "a repeat verdict after waking was switched off posts no stop notice and stops nothing" do
    sweep(lume: 0.9)
    finish_runs
    post(@lume, "Still waiting on CI.", at: 1.second.from_now)
    flip = lambda do |state:, questions:|
      Setting.instance.update!(stalled_sweep_wake: false)
      answers(lume: 0.9).call(state: state, questions: questions)
    end
    sweeper(decide: flip).call
    assert_equal 0, stop_notices
    last = StalledThreadSweep.order(:id).last
    assert_not last.stopped
    assert_equal [ "wake_off" ], last.held.pluck("reason")

    Setting.instance.update!(stalled_sweep_wake: true)
    post(@lume, "Hm.", at: 2.seconds.from_now)
    opt_out = lambda do |state:, questions:|
      @lume.account.update!(stalled_sweep_enabled: false)
      answers(lume: 0.9).call(state: state, questions: questions)
    end
    sweeper(decide: opt_out).call
    assert_equal 0, stop_notices
    assert_equal [ "account_not_opted_in" ], StalledThreadSweep.order(:id).last.held.pluck("reason")
  end

  test "switching waking on doesn't act on states already judged in shadow; only new states can wake" do
    Setting.instance.update!(stalled_sweep_wake: false)
    sweep(lume: 0.9, wake: false)
    Setting.instance.update!(stalled_sweep_wake: true)
    assert_no_difference(-> { AgentRuntimeInteraction.count }) { sweep(lume: 0.9) }

    post(@mira, "CI is green on abc123.", at: 1.second.from_now)
    assert_difference(-> { AgentRuntimeInteraction.count }, 1) { sweep(lume: 0.9) }
  end

  test "a wake revoked after it was reserved is cancelled before it starts" do
    sweep(lume: 0.9)
    run = @chat.agent_runtime_interactions.sole
    @lume.account.update!(stalled_sweep_enabled: false)
    ManualAgentResponseJob.perform_now(@chat, @lume, runtime_interaction_id: run.id)
    assert_equal "cancelled", run.reload.execution_state

    @lume.account.update!(stalled_sweep_enabled: true)
    post(@person, "New stretch.", at: 1.second.from_now)
    post(@lume, "Ok.", at: 2.seconds.from_now)
    sweep(lume: 0.9)
    later = @chat.agent_runtime_interactions.order(:id).last
    Setting.instance.update!(stalled_sweep_wake: false)
    assert_not later.claim_dispatch!
    assert_equal "cancelled", later.reload.execution_state
  end

  test "a pause at the claim boundary stops the run" do
    sweep(lume: 0.9)
    run = @chat.agent_runtime_interactions.sole
    @lume.update!(paused: true)
    assert_not run.claim_dispatch!
    assert_equal "cancelled", run.reload.execution_state
  end

  test "a pause after reservation cancels the run in the job" do
    sweep(lume: 0.9)
    run = @chat.agent_runtime_interactions.sole
    @lume.update!(paused: true)
    ManualAgentResponseJob.perform_now(@chat, @lume, runtime_interaction_id: run.id)
    assert_equal "cancelled", run.reload.execution_state
  end

  test "paused residents are never woken" do
    @lume.update!(paused: true)
    assert_no_difference(-> { AgentRuntimeInteraction.count }) { sweep(lume: 0.9) }
    assert_equal [ "paused" ], StalledThreadSweep.sole.held.pluck("reason")
  end

  # Identity

  test "a guest resident sharing a resident's name is not woken by the other's score" do
    guest = agents(:other_account_agent)
    make_runnable(guest)
    guest.update!(name: @lume.name)
    GuestMembership.create!(account: @chat.account, agent: guest, added_by: @person)
    @chat.agents << guest
    @chat.chat_agents.update_all(created_at: 1.day.ago)
    decide = ->(**) { { "can_act:1" => 0.1, "can_act:2" => 0.1, "can_act:3" => 0.9, "person_holds" => 0.1 } }

    sweeper(decide: decide).call

    assert_equal [ guest ], @chat.agent_runtime_interactions.map(&:agent)
    assert_equal [ guest.id ], StalledThreadSweep.sole.would_wake_agent_ids
  end

  test "a resident who left during inference is not woken" do
    leave = lambda do |state:, questions:|
      @chat.chat_agents.where(agent: @lume).destroy_all
      answers(lume: 0.9).call(state: state, questions: questions)
    end
    assert_no_difference(-> { AgentRuntimeInteraction.count }) { sweeper(decide: leave).call }
    assert_equal [ [ @lume.id, "not_in_room" ] ], StalledThreadSweep.sole.held.map { |h| h.values_at("agent_id", "reason") }
  end

  test "nothing happens if the room moved on before the wake" do
    StalledThreadSweeper.new(now: 1.hour.from_now, interval: 10.minutes, window: 1.day, wake: false, decide: answers(lume: 0.9)).call
    post(@person, "Never mind, I merged it.", at: 1.second.from_now)
    assert_no_difference(-> { AgentRuntimeInteraction.count }) { StalledThreadWake.new(StalledThreadSweep.sole).call }
  end

  private

  def make_runnable(agent)
    agent.update!(runtime: "external", uuid: SecureRandom.uuid_v7, endpoint_url: "https://agent.example.com",
      trigger_bearer_token: "tr_valid", health_state: "healthy", consecutive_health_failures: 0)
  end

  # A wide window: these tests are about waking, not about which rooms are recent enough.
  def sweeper(decide:, wake: true)
    StalledThreadSweeper.new(now: 1.hour.from_now, interval: 10.minutes, window: 1.day, wake: wake, decide: decide)
  end

  def sweep(lume: 0.1, mira: 0.1, wake: true)
    sweeper(decide: answers(lume: lume, mira: mira), wake: wake).call
  end

  def answers(lume: 0.1, mira: 0.1)
    ->(**) { { "can_act:1" => lume, "can_act:2" => mira, "person_holds" => 0.1 } }
  end

  def stop_notices
    @chat.messages.where("content LIKE ?", "%won't wake anyone here again%").count
  end

  def finish_runs
    @chat.agent_runtime_interactions.update_all(finished_at: Time.current, execution_state: "completed")
  end

  def post(author, content, at:)
    attributes = author.is_a?(Agent) ? { role: "assistant", agent: author } : { role: "user", user: author }
    message = @chat.messages.create!(content: content, **attributes)
    message.update_columns(created_at: at, updated_at: at)
    message
  end

end
