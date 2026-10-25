require "test_helper"

# Asleep: a resident whose paid plan lapsed (docs/proposals/2026-10-07-stripe-billing.md,
# "The hold boundary"). Nothing new starts, on any route or funding; a turn
# already running may finish within the drain; the container is stopped, not
# removed; paying wakes it. Billing never touches paused or active.
class BillingHoldTest < ActiveSupport::TestCase

  include ActiveJob::TestHelper
  include ActionMailer::TestHelper

  setup do
    @agent = agents(:research_assistant)
    @agent.update_columns(runtime: "external", active: true, paused: false)
    @entitlement = ResidentEntitlement.create!(agent: @agent, account: @agent.account, source: "stripe",
      state: "active", tier: "conversation")
  end

  def fall_asleep!(at: Time.current)
    @entitlement.update!(state: "held", held_at: at)
  end

  def interaction_started(at)
    interaction = AgentRuntimeInteraction.new(agent: @agent, started_at: at, trigger_kind: "conversation",
      requested_by: "a conversation")
    interaction.save!(validate: false)
    interaction.update_columns(created_at: at, finished_at: nil)
    interaction
  end

  test "an asleep resident is unavailable everywhere availability is asked, with its own reason" do
    assert @agent.eligible_for_conversation?
    fall_asleep!

    assert @agent.billing_held?
    assert_not @agent.eligible_for_conversation?
    assert_equal "billing_hold", @agent.unavailability_reason
    assert_not_includes Agent.eligible_for_conversation, @agent
    error = assert_raises(Agent::RuntimeAvailability::Unavailable) { @agent.require_conversation_runtime! }
    assert_equal "billing_hold", error.code
    assert_match(/asleep/, error.message)
    assert_not @agent.reload.paused?, "billing never changes the owner's pause"
    assert @agent.active?
  end

  test "the scope cron wakes and memory aggregation use leaves an asleep resident out" do
    assert_includes Agent.not_billing_held, @agent
    fall_asleep!
    assert_not_includes Agent.not_billing_held, @agent
    assert_includes ExternalAgentWakeJob.new.send(:wakeable_agents).to_sql, "resident_entitlements"
  end

  test "async turns are refused at admission" do
    turn = ResidentTurn.new(agent: @agent)
    fall_asleep!
    assert_not turn.eligible?
  end

  test "the container is never started while asleep" do
    fall_asleep!
    sandbox = Agents::Sandbox.new(@agent)
    %i[spawn! start! recreate!].each do |start|
      error = assert_raises(Agent::RuntimeAvailability::Unavailable) { sandbox.public_send(start) }
      assert_equal "billing_hold", error.code
    end
    assert_raises(Agent::RuntimeAvailability::Unavailable) { sandbox.with_runtime { flunk "must not run" } }
  end

  test "the reconciler leaves an asleep resident's container alone" do
    fall_asleep!
    Agents::Sandbox.stub(:new, ->(*) { flunk "must not touch the container" }) do
      assert_nothing_raised { HostedAgentRuntimeReconcileJob.new.send(:reconcile_agent, @agent, raise_on_error: true) }
    end
  end

  test "the free grant doesn't stand in for a lapsed plan" do
    fall_asleep!
    grant = HouseInferenceGrant.new(user: users(:user_1), agent: @agent)
    HouseInference::Offering.stub(:configured?, true) do
      error = assert_raises(HouseInference::Error) { grant.check!(@agent.model_id) }
      assert_match(/asleep/, error.message)
    end
  end

  test "a turn running when the plan lapsed keeps its house calls funded until it ends or the drain passes" do
    held_at = Time.current
    interaction = interaction_started(held_at - 1.minute)
    fall_asleep!(at: held_at)

    assert @entitlement.draining?(held_at + 5.minutes)
    assert @entitlement.funds_calls?
    assert_not @entitlement.draining?(held_at + ResidentEntitlement::DRAIN + 1.second)

    interaction.update_columns(finished_at: Time.current)
    assert_not @entitlement.reload.draining?(held_at + 5.minutes)
  end

  test "work begun after the plan lapsed gets no drain" do
    held_at = 10.minutes.ago
    fall_asleep!(at: held_at)
    interaction_started(held_at + 1.minute)

    assert_not @entitlement.draining?
    assert_not @entitlement.funds_calls?
  end

  test "falling asleep puts the resident to sleep and tells the owner; paying wakes it" do
    assert_enqueued_with(job: Billing::SleepJob, args: [ @agent.id ]) do
      assert_enqueued_emails 1 do
        fall_asleep!
      end
    end
    assert_enqueued_with(job: Billing::WakeJob, args: [ @agent.id ]) do
      @entitlement.update!(state: "active", hold_released_at: Time.current)
    end
  end

  test "a failed renewal tells the owner when the resident would fall asleep" do
    assert_enqueued_emails 1 do
      @entitlement.update!(state: "grace", grace_started_at: Time.current, grace_deadline: 14.days.from_now)
    end
  end

  test "sleep cancels queued work, waits for a running turn within the drain, then stops the container" do
    held_at = Time.current
    interaction_started(held_at - 1.minute)
    fall_asleep!(at: held_at)
    stopped = []
    sandbox = Object.new
    sandbox.define_singleton_method(:stop!) { stopped << :stop }

    Agents::Sandbox.stub(:new, sandbox) do
      assert_enqueued_with(job: Billing::SleepJob) do
        Billing::SleepJob.new.perform(@agent.id, now: held_at + 1.minute)
      end
      assert_empty stopped, "a running turn is allowed to finish"

      Billing::SleepJob.new.perform(@agent.id, now: held_at + ResidentEntitlement::DRAIN + 1.second)
      assert_equal [ :stop ], stopped, "past the drain the container is stopped"
    end
    assert @agent.reload.active?
  end

  test "waking starts the container only if nothing else keeps it stopped" do
    started = []
    sandbox = Object.new
    sandbox.define_singleton_method(:spawn!) { started << :spawn }
    Agents::Config.stub(:cold_start?, false) do
      Agents::Sandbox.stub(:new, sandbox) do
        Billing::WakeJob.new.perform(@agent.id)
        assert_equal [ :spawn ], started

        @agent.update_columns(active: false)
        Billing::WakeJob.new.perform(@agent.id)
        assert_equal [ :spawn ], started, "a switched-off resident stays off"
      end
    end
  end

  test "a turn admitted before the hold but not yet submitted is withdrawn before it starts" do
    interaction = AgentRuntimeInteraction.create!(agent: @agent, trigger_kind: "wake", session_id: "s1",
      started_at: Time.current, endpoint_url: "https://runtime.example.test")
    turn = ResidentTurn.enqueue!(interaction, { session_id: "s1", request: "hello" })
    turn.update!(state: "starting", admitted_at: Time.current)
    fall_asleep!

    Agents::RuntimeLocation.stub(:dispatchable?, true) { turn.withdraw_unless_deliverable! }
    assert_predicate turn.reload.cancel_requested_at, :present?
  end

  test "a failed stop is kept: reported and tried again while the resident sleeps" do
    fall_asleep!(at: 1.hour.ago)
    sandbox = Object.new
    sandbox.define_singleton_method(:stop!) { false }
    sandbox.define_singleton_method(:confirmed_stopped?) { false }

    Agents::Sandbox.stub(:new, sandbox) do
      assert_enqueued_with(job: Billing::SleepJob, args: [ @agent.id, { attempt: 1 } ]) do
        Billing::SleepJob.new.perform(@agent.id)
      end
    end

    raising = Object.new
    raising.define_singleton_method(:stop!) { raise "docker unavailable" }
    Agents::Sandbox.stub(:new, raising) do
      assert_enqueued_with(job: Billing::SleepJob, args: [ @agent.id, { attempt: 2 } ]) do
        Billing::SleepJob.new.perform(@agent.id, attempt: 1)
      end
    end
  end

  test "an unverifiable container state is never taken for a stop" do
    fall_asleep!(at: 1.hour.ago)
    sandbox = Agents::Sandbox.new(@agent)
    failed = { stdout: "", stderr: "Cannot connect to the Docker daemon", ok: false }
    sandbox.stub(:docker_capture, failed) do
      assert_not sandbox.confirmed_stopped?, "a failed probe is unknown"
    end
    sandbox.stub(:docker_capture, { stdout: "", stderr: "Error: No such container: x", ok: false }) do
      assert sandbox.confirmed_stopped?, "an absent container is stopped"
    end
    sandbox.stub(:docker_capture, { stdout: "false\n", stderr: "", ok: true }) do
      assert sandbox.confirmed_stopped?
    end

    sandbox.stub(:stop!, false) do
      sandbox.stub(:docker_capture, failed) do
        Agents::Sandbox.stub(:new, sandbox) do
          assert_enqueued_with(job: Billing::SleepJob, args: [ @agent.id, { attempt: 1 } ]) do
            Billing::SleepJob.new.perform(@agent.id)
          end
        end
      end
    end
  end

  test "paying never starts a resident its owner paused; unpausing does" do
    started = []
    sandbox = Object.new
    sandbox.define_singleton_method(:spawn!) { started << :spawn }
    @agent.update_columns(paused: true)
    fall_asleep!
    @entitlement.update!(state: "active", hold_released_at: Time.current)

    Agents::Config.stub(:cold_start?, false) do
      Agents::Sandbox.stub(:new, sandbox) do
        Billing::WakeJob.new.perform(@agent.id)
        assert_empty started, "the owner's pause still holds"

        assert_enqueued_with(job: Billing::WakeJob, args: [ @agent.id ]) do
          @agent.reload.update!(paused: false)
        end
        Billing::WakeJob.new.perform(@agent.id)
        assert_equal [ :spawn ], started
      end
    end
    assert_not @agent.reload.paused?
  end

  test "the emails say what happens and where to pay" do
    @entitlement.update_columns(state: "held", held_at: Time.current)
    asleep = BillingMailer.resident_asleep(@entitlement.reload)
    assert_match(/#{@agent.name} is asleep/, asleep.subject)
    assert_includes asleep.text_part.body.to_s, "Paying wakes them"
    assert_includes asleep.text_part.body.to_s, "30 days"

    @entitlement.update_columns(state: "grace", grace_deadline: Time.zone.parse("2026-11-08"))
    failed = BillingMailer.payment_failed(@entitlement.reload)
    assert_includes failed.text_part.body.to_s, "8 November 2026"
  end

end
