require "test_helper"

class BoatPowerTest < ActiveSupport::TestCase

  # Stands in for BoatClient: a sandbox the tests move by hand, and a record
  # of every resume. It has no stop: BoatPower never sends one.
  class FakeClient

    attr_reader :resumes
    attr_accessor :sandbox, :on_resume, :on_find

    def initialize
      @resumes = []
    end

    def find_sandbox(_id)
      on_find&.call
      sandbox
    end

    def resume_sandbox(id, placement_id:)
      @resumes << [ id, placement_id ]
      on_resume ? on_resume.call : sandbox
    end

  end

  SANDBOX_ID = "bx_23456789".freeze

  setup do
    @admin = users(:site_admin_user)
    @client = FakeClient.new
    @now = Time.zone.parse("2026-11-12 20:00:00")
    @placement = AgentPlacement.create!(agent: agents(:research_assistant), backend: "boat", state: "ready",
      provider_sandbox_id: SANDBOX_ID)
    @enrollment, = RunnerEnrollment.mint!(placement: @placement)
    @client.sandbox = sandbox(state: "ready")
  end

  def power(clock: -> { @now }) = BoatPower.new(client: @client, clock:)

  def sandbox(state:, stop: nil)
    BoatClient::Sandbox.new(id: SANDBOX_ID, name: "souls-house", state:, size: "small", error: nil, stopped_at: nil,
      data_expired_at: nil, labels: {}, setup_status: "done", setup_error: nil, stop:, ttl_seconds: nil)
  end

  def stop(status:)
    BoatClient::Stop.new(id: "stop_aaaa", status:, requested_at: nil, ended_at: nil, forced: false)
  end

  def enqueue!
    RunnerCommand.enqueue!(enrollment: @enrollment, kind: "home_stats", payload: {})
  end

  def reload = @placement.reload

  def heartbeat!(epoch)
    BoatPower.observe_heartbeat!(reload, { "power_epoch" => epoch })
  end

  test "a boat placement starts awake and other backends have no power state" do
    assert_equal "awake", @placement.power_state
    assert_nil AgentPlacement.new(agent: agents(:research_assistant), backend: "local", state: "ready").tap(&:valid?).power_state
    assert_equal "awake", reload.power_state
  end

  test "BoatPower has no way to stop a box" do
    assert_not BoatPower.new(client: @client).respond_to?(:request_stop!)
    assert_not BoatPower.private_method_defined?(:send_stop!)
    assert_not FakeClient.method_defined?(:stop_sandbox), "the fake would record a stop if one were sent"
  end

  test "a box stopped outside the house is read, resumed under a new epoch, and awake once read awake" do
    @client.sandbox = sandbox(state: "archived", stop: stop(status: "completed"))
    enqueue!

    assert_equal :waking, power.reconcile!(@placement).outcome
    assert_equal [ [ SANDBOX_ID, @placement.id ] ], @client.resumes
    assert_equal [ "waking", 2 ], [ reload.power_state, reload.power_epoch ]

    @client.sandbox = sandbox(state: "ready", stop: stop(status: "superseded"))
    assert_equal :awake, power.reconcile!(@placement).outcome
    assert_equal [ "awake", 2 ], [ reload.power_state, reload.power_epoch ]
    assert_equal 1, @client.resumes.size
  end

  test "a box with a live stop is resumed, which supersedes the stop" do
    @client.sandbox = sandbox(state: "archiving", stop: stop(status: "failing"))
    enqueue!
    assert_equal :waking, power.reconcile!(@placement).outcome
    assert_equal 1, @client.resumes.size
  end

  test "of two workers that read the same asleep box, only one resumes it" do
    @client.sandbox = sandbox(state: "archived")
    enqueue!
    stale = AgentPlacement.find(@placement.id)
    power.reconcile!(@placement)

    assert_equal :superseded, power.send(:resume!, stale).outcome
    assert_equal 1, @client.resumes.size
  end

  test "a resume refused because a stop holds the machine waits for Retry-After and reads again" do
    @client.sandbox = sandbox(state: "archiving", stop: stop(status: "pending"))
    enqueue!
    @client.on_resume = -> { raise BoatClient::SandboxStopping.new("Boat sandbox_stopping (HTTP 409)", status: 409, code: "sandbox_stopping", retry_after: 20) }

    result = power.reconcile!(@placement)
    assert_equal [ :wake_deferred, 20.seconds ], [ result.outcome, result.retry_after ]
    assert_equal "waking", reload.power_state

    @client.on_resume = nil
    @client.sandbox = sandbox(state: "archived")
    assert_equal :waking, power.reconcile!(@placement).outcome
    assert_equal 2, @client.resumes.size
  end

  test "a resume is sent only after a read shows the box asleep or stopping" do
    enqueue!
    assert_equal :awake, power.reconcile!(@placement).outcome
    assert_empty @client.resumes

    @client.sandbox = sandbox(state: "provisioning")
    assert_equal :settling, power.reconcile!(@placement).outcome
    assert_empty @client.resumes
  end

  test "with nothing waiting, reconcile reads nothing and does nothing" do
    @client.sandbox = nil
    assert_equal :idle, power.reconcile!(@placement).outcome
    assert_not reload.power_review?
  end

  test "a wake is satisfied only by a heartbeat stamped with the current epoch, after the box is read awake" do
    @client.sandbox = sandbox(state: "archived")
    enqueue!
    power.reconcile!(@placement)
    epoch = reload.power_epoch

    assert_not heartbeat!(epoch - 1), "an old epoch proves nothing"
    assert_not heartbeat!(epoch), "not before the house has read the box awake"

    @client.sandbox = sandbox(state: "ready")
    power.reconcile!(@placement)
    assert heartbeat!(epoch)
    assert_not reload.wake_pending?
  end

  test "a wake clears only the requests a read has confirmed" do
    enqueue!
    enqueue!
    assert_equal [ 2, 1 ], [ reload.wake_request_version, reload.power_epoch ], "only the first waiting request moves the epoch"
    assert_not heartbeat!(1), "no read has seen the box yet"

    assert_equal :awake, power.reconcile!(@placement).outcome
    assert_equal 2, reload.wake_confirmed_version
    assert heartbeat!(1)
    assert_equal 2, reload.wake_satisfied_version

    enqueue!
    assert reload.wake_pending?
    assert_equal 2, reload.power_epoch
    assert_not heartbeat!(2), "the new request has not been read for"
  end

  test "a request made during the read is not confirmed by it" do
    enqueue!
    @client.on_find = -> { enqueue! }
    power.reconcile!(@placement)
    @client.on_find = nil

    assert_equal [ 2, 1 ], [ reload.wake_request_version, reload.wake_confirmed_version ]
    assert heartbeat!(reload.power_epoch)
    assert_equal 1, reload.wake_satisfied_version
    assert reload.wake_pending?, "the request made during the read waits for the next read"

    power.reconcile!(@placement)
    assert heartbeat!(reload.power_epoch)
    assert_not reload.wake_pending?
  end

  test "a read made before the placement moved confirms nothing" do
    enqueue!
    stale = AgentPlacement.find(@placement.id)
    AgentPlacement.where(id: @placement.id).update_all(power_epoch: stale.power_epoch + 1)

    assert_equal :superseded, power.send(:wake!, stale).outcome
    assert_equal 0, reload.wake_confirmed_version
  end

  test "a heartbeat stamped before a wake was requested cannot satisfy it" do
    epoch_before = reload.power_epoch
    enqueue!
    assert_not heartbeat!(epoch_before), "a delayed heartbeat from before the request proves nothing about the box now"
    assert reload.wake_pending?
    assert_equal({ "power_epoch" => epoch_before + 1 }, BoatPower.heartbeat_answer(reload))
    assert_not heartbeat!(epoch_before + 1), "nor does a current one before the box is read"
    power.reconcile!(@placement)
    assert heartbeat!(epoch_before + 1)
  end

  test "a runner heartbeating with the new epoch from a box whose stop is live satisfies nothing; the read resumes it" do
    @client.sandbox = sandbox(state: "archiving", stop: stop(status: "pending"))
    enqueue!
    epoch = BoatPower.heartbeat_answer(reload)["power_epoch"]
    assert_not heartbeat!(epoch), "the runner can still answer while its box archives"
    assert_not heartbeat!(epoch)
    assert reload.wake_pending?

    assert_equal :waking, power.reconcile!(@placement).outcome
    assert_equal 1, @client.resumes.size
    assert_not heartbeat!(reload.power_epoch), "waking is not awake"

    @client.sandbox = sandbox(state: "ready", stop: stop(status: "superseded"))
    assert_equal :awake, power.reconcile!(@placement).outcome
    assert heartbeat!(reload.power_epoch)
    assert_not reload.wake_pending?
  end

  test "only the first waiting request starts a job chain" do
    assert_enqueued_jobs 1, only: BoatPowerJob do
      enqueue!
      enqueue!
    end
  end

  test "the first kick waits for the enqueue to commit, so the job cannot read the house before the command exists" do
    AgentPlacement.transaction do
      enqueue!
      assert reload.wake_pending?
      assert_no_enqueued_jobs(only: BoatPowerJob)
    end
    assert_enqueued_jobs 1, only: BoatPowerJob
  end

  test "a rolled-back enqueue leaves no wake and kicks nothing; the next one starts the chain" do
    AgentPlacement.transaction do
      enqueue!
      raise ActiveRecord::Rollback
    end
    assert_not reload.wake_pending?
    assert_equal 0, RunnerCommand.where(agent_placement_id: @placement.id).count
    assert_no_enqueued_jobs(only: BoatPowerJob)

    assert_enqueued_jobs(1, only: BoatPowerJob) { enqueue! }
  end

  test "a missing or failed box goes to review instead of being woken, and the job stops polling" do
    enqueue!
    @client.sandbox = nil
    assert_equal :review, power.reconcile!(@placement).outcome
    assert_equal "sandbox_missing", reload.power_review_reason
    assert_empty @client.resumes

    BoatPower.stub(:from_credentials, power) do
      assert_no_enqueued_jobs(only: BoatPowerJob) { BoatPowerJob.perform_now(@placement.id) }
    end
  end

  test "an admin clears a review and the waiting wake is picked up again" do
    enqueue!
    @placement.update!(power_review_at: @now, power_review_reason: "sandbox_missing")
    assert_raises(BoatPower::NotAuthorized) { power.clear_power_review!(@placement, requested_by: users(:regular_user)) }

    assert_enqueued_with(job: BoatPowerJob, args: [ @placement.id ]) do
      power.clear_power_review!(@placement, requested_by: @admin)
    end
    assert_not reload.power_review?
  end

  test "placements that are not ready Boat boxes are left alone" do
    @placement.update!(state: "retired")
    enqueue!
    assert_equal :not_powered, power.reconcile!(@placement).outcome
    assert_empty @client.resumes
  end

  test "the job keeps checking while a wake waits, honours Retry-After, and stops checking when settled" do
    BoatPower.stub(:from_credentials, power) do
      enqueue!
      @client.sandbox = sandbox(state: "ready")
      assert_enqueued_with(job: BoatPowerJob, args: [ @placement.id ]) { BoatPowerJob.perform_now(@placement.id) }

      heartbeat!(reload.power_epoch)
      assert_no_enqueued_jobs(only: BoatPowerJob) { BoatPowerJob.perform_now(@placement.id) }

      enqueue!
      @client.sandbox = sandbox(state: "archived")
      @client.on_resume = -> { raise BoatClient::CapacityUnavailable.new("Boat rate_limited (HTTP 429)", status: 429, code: "rate_limited", retry_after: 90) }
      freeze_time do
        assert_enqueued_with(job: BoatPowerJob, at: 90.seconds.from_now) { BoatPowerJob.perform_now(@placement.id) }
      end
    end
  end

end
