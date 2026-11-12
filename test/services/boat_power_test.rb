require "test_helper"

class BoatPowerTest < ActiveSupport::TestCase

  # Stands in for BoatClient: a sandbox the tests move by hand, and a record
  # of every request that could change it.
  class FakeClient

    attr_reader :stops, :resumes, :stop_reads
    attr_accessor :sandbox, :on_stop, :on_resume, :stops_by_id

    def initialize
      @stops = []
      @resumes = []
      @stop_reads = []
      @stops_by_id = {}
    end

    def find_sandbox(_id) = sandbox

    def stop_sandbox(id, placement_id:)
      @stops << [ id, placement_id ]
      on_stop.call
    end

    def resume_sandbox(id, placement_id:)
      @resumes << [ id, placement_id ]
      on_resume ? on_resume.call : sandbox
    end

    def find_stop(_sandbox_id, stop_id)
      @stop_reads << stop_id
      stops_by_id[stop_id]
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

  def stop(id: "stop_aaaa", status: "pending", requested_at: @now + 1.second)
    BoatClient::Stop.new(id:, status:, requested_at:, ended_at: nil, forced: false)
  end

  def accepted(stop_op, already_stopped: false)
    BoatClient::StopAccepted.new(sandbox_id: SANDBOX_ID, stop: stop_op, already_stopped:)
  end

  def enqueue!
    RunnerCommand.enqueue!(enrollment: @enrollment, kind: "home_stats", payload: {})
  end

  def reload = @placement.reload

  def heartbeat!(epoch)
    BoatPower.observe_heartbeat!(reload, { "power_epoch" => epoch })
  end

  # The stop answered, the box archives: stopped, with the stop recorded.
  def stop_box!
    power.request_stop!(@placement, requested_by: @admin)
    @client.on_stop = lambda {
      @client.sandbox = sandbox(state: "archiving", stop: stop)
      accepted(stop)
    }
    power.reconcile!(@placement)
    @client.sandbox = sandbox(state: "archived", stop: stop(status: "completed", requested_at: nil))
    power.reconcile!(@placement)
    assert_equal "stopped", reload.power_state
  end

  test "a boat placement starts awake and other backends have no power state" do
    assert_equal "awake", @placement.power_state
    assert_nil AgentPlacement.new(agent: agents(:research_assistant), backend: "local", state: "ready").tap(&:valid?).power_state
  end

  test "an admin stop commits the intent before any request, then sends one stop and settles by reading" do
    power.request_stop!(@placement, requested_by: @admin)
    assert_equal [ "stopping", 1 ], [ reload.power_state, reload.power_epoch ]
    assert_empty @client.stops

    @client.on_stop = lambda {
      @client.sandbox = sandbox(state: "archiving", stop: stop)
      accepted(stop)
    }
    assert_equal :stopping, power.reconcile!(@placement).outcome
    assert_equal 1, @client.stops.size
    assert_equal [ "stop_aaaa", 1 ], [ reload.stop_id, reload.stop_epoch ]

    # The sandbox drops requestedAt once the stop ends; the recorded id is
    # what proves it ours.
    @client.sandbox = sandbox(state: "archived", stop: stop(status: "completed", requested_at: nil))
    assert_equal :stopped, power.reconcile!(@placement).outcome
    assert_equal "stopped", reload.power_state
    assert_equal 1, @client.stops.size
    assert_not reload.power_review?
  end

  test "only an installation admin can stop, and never with a command in flight, a wake waiting or a review" do
    assert_raises(BoatPower::NotAuthorized) { power.request_stop!(@placement, requested_by: users(:regular_user)) }

    command = enqueue!
    assert_raises(BoatPower::NotAllowed) { power.request_stop!(@placement, requested_by: @admin) }
    command.update!(state: "done")
    assert_raises(BoatPower::NotAllowed) { power.request_stop!(@placement, requested_by: @admin) } # wake pending
    heartbeat!(0)
    @placement.update!(power_review_at: @now, power_review_reason: "stop_unresolved")
    assert_raises(BoatPower::NotAllowed) { power.request_stop!(@placement, requested_by: @admin) }
    assert_equal "awake", reload.power_state
  end

  test "a stale worker that read the stop intent sends nothing once a wake has moved the epoch on" do
    power.request_stop!(@placement, requested_by: @admin)
    stale = AgentPlacement.find(@placement.id) # what the original worker read before it paused

    enqueue! # the wake arrives before any stop was sent
    assert_equal :stop_cancelled, power.reconcile!(@placement).outcome
    assert_equal [ "awake", 2 ], [ reload.power_state, reload.power_epoch ]

    # The original worker resumes long after, holding the old epoch.
    @client.on_stop = -> { flunk "a stale worker must not send a stop" }
    assert_equal :superseded, power.send(:send_or_cancel_stop!, stale).outcome
    assert_empty @client.stops
    assert_equal "awake", reload.power_state
  end

  test "of two workers holding the same stop intent, only one sends" do
    power.request_stop!(@placement, requested_by: @admin)
    first = AgentPlacement.find(@placement.id)
    second = AgentPlacement.find(@placement.id)
    @client.on_stop = lambda {
      @client.sandbox = sandbox(state: "archiving", stop: stop)
      accepted(stop)
    }

    power.send(:send_or_cancel_stop!, first)
    power.send(:send_or_cancel_stop!, second)

    assert_equal 1, @client.stops.size
  end

  test "a stop that times out is unresolved: review, and no return to awake or resend as time passes" do
    power.request_stop!(@placement, requested_by: @admin)
    @client.on_stop = -> { raise BoatClient::Error.new("Could not reach Boat (Net::ReadTimeout)", code: "unavailable") }

    assert_equal :stop_unresolved, power.reconcile!(@placement).outcome
    assert reload.power_review?
    assert_equal "stop_unresolved", reload.power_review_reason

    later = power(clock: -> { @now + 6.hours })
    assert_equal :stop_unresolved, later.reconcile!(@placement).outcome
    assert_equal "stopping", reload.power_state
    assert_equal 1, @client.stops.size
  end

  test "a timed-out stop that Boat did accept is resolved by the stop it shows, read by id" do
    power.request_stop!(@placement, requested_by: @admin)
    @client.on_stop = lambda {
      @client.sandbox = sandbox(state: "archived", stop: stop(status: "completed", requested_at: nil))
      raise BoatClient::Error.new("Could not reach Boat (Net::ReadTimeout)", code: "unavailable")
    }
    @client.stops_by_id["stop_aaaa"] = stop(status: "completed", requested_at: @now + 2.seconds)

    assert_equal :stopped, power.reconcile!(@placement).outcome
    assert_equal [ "stopped", "stop_aaaa" ], [ reload.power_state, reload.stop_id ]
    assert_not reload.power_review?
  end

  test "an old completed stop never counts as this one" do
    stop_box!
    command = enqueue!
    @client.sandbox = sandbox(state: "archived", stop: stop(status: "completed", requested_at: nil))
    power.reconcile!(@placement) # resume
    @client.sandbox = sandbox(state: "ready", stop: stop(status: "superseded", requested_at: nil))
    power.reconcile!(@placement)
    heartbeat!(reload.power_epoch)
    assert_equal "awake", reload.power_state
    command.update!(state: "done")

    power.request_stop!(@placement, requested_by: @admin)
    # Boat answers nothing, and the box still shows the earlier stop, or a
    # stop accepted before this one's intent.
    @client.on_stop = -> { raise BoatClient::Error.new("Boat http_502 (HTTP 502)", status: 502, code: "http_502") }
    @client.stops_by_id["stop_bbbb"] = stop(id: "stop_bbbb", status: "completed", requested_at: @now - 1.hour)
    @client.sandbox = sandbox(state: "archived", stop: stop(status: "completed", requested_at: nil))
    assert_equal :stop_unresolved, power.reconcile!(@placement).outcome

    @client.sandbox = sandbox(state: "archived", stop: stop(id: "stop_bbbb", status: "completed", requested_at: nil))
    assert_equal :stop_unresolved, power.reconcile!(@placement).outcome
    assert_equal "stopping", reload.power_state
    assert reload.power_review?
  end

  test "a restart between Boat's answer and the local write is settled by reading, not by sending again" do
    power.request_stop!(@placement, requested_by: @admin)
    @client.on_stop = lambda {
      @client.sandbox = sandbox(state: "archiving", stop: stop)
      raise "worker killed after Boat answered"
    }
    assert_raises(RuntimeError) { power.reconcile!(@placement) }
    assert_nil reload.stop_id
    assert reload.stop_sent_at

    @client.stops_by_id["stop_aaaa"] = stop
    assert_equal :stopping, power.reconcile!(@placement).outcome
    assert_equal "stop_aaaa", reload.stop_id
    assert_equal 1, @client.stops.size
  end

  test "a refused stop never lands: back to awake under a new epoch, in review" do
    power.request_stop!(@placement, requested_by: @admin)
    @client.on_stop = -> { raise BoatClient::Error.new("Boat bad_request (HTTP 400)", status: 400, code: "bad_request") }

    assert_equal :review, power.reconcile!(@placement).outcome
    assert_equal [ "awake", 2 ], [ reload.power_state, reload.power_epoch ]
    assert_equal "stop_refused_bad_request", reload.power_review_reason
  end

  test "a failing stop is still live and is never forced" do
    power.request_stop!(@placement, requested_by: @admin)
    @client.on_stop = lambda {
      @client.sandbox = sandbox(state: "ready", stop: stop(status: "failing"))
      accepted(stop(status: "failing"))
    }

    assert_equal :stopping, power.reconcile!(@placement).outcome
    assert_equal :stopping, power.reconcile!(@placement).outcome
    assert_equal "stopping", reload.power_state
    assert_equal 1, @client.stops.size
  end

  test "a command enqueued during the stop call waits; the stop settles, then a resume wakes the box" do
    power.request_stop!(@placement, requested_by: @admin)
    @client.on_stop = lambda {
      enqueue! # arrives while the stop request is in the air
      @client.sandbox = sandbox(state: "archiving", stop: stop)
      accepted(stop)
    }

    # The stop is live; the resume supersedes it.
    assert_equal :waking, power.reconcile!(@placement).outcome
    assert_equal 1, @client.resumes.size
    assert_equal [ "waking", 2 ], [ reload.power_state, reload.power_epoch ]
    assert reload.wake_pending?

    @client.sandbox = sandbox(state: "ready", stop: stop(status: "superseded", requested_at: nil))
    assert_equal :awake, power.reconcile!(@placement).outcome
    assert_equal "awake", reload.power_state
  end

  test "a resume refused because a stop holds the machine waits for Retry-After and reads again" do
    stop_box!
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
    @placement.update!(power_state: "stopped")
    assert_equal :settling, power.reconcile!(@placement).outcome
    assert_empty @client.resumes
  end

  test "a wake is satisfied only by a heartbeat stamped with the current epoch, after the box is read awake" do
    stop_box!
    enqueue!
    @client.sandbox = sandbox(state: "archived", stop: stop(status: "completed", requested_at: nil))
    power.reconcile!(@placement)
    epoch = reload.power_epoch

    assert_not heartbeat!(epoch - 1), "an old epoch proves nothing"
    assert_not heartbeat!(epoch), "not before the house has read the box awake"

    @client.sandbox = sandbox(state: "ready", stop: stop(status: "superseded", requested_at: nil))
    power.reconcile!(@placement)
    assert heartbeat!(epoch)
    assert_not reload.wake_pending?
  end

  test "a wake clears only the requests the heartbeat's statement read" do
    enqueue!
    enqueue!
    assert_equal 2, reload.wake_request_version
    assert heartbeat!(0)
    assert_equal 2, reload.wake_satisfied_version

    enqueue!
    assert reload.wake_pending?
  end

  test "only the first waiting request starts a job chain" do
    assert_enqueued_jobs 1, only: BoatPowerJob do
      enqueue!
      enqueue!
    end
  end

  test "no late stop after a wake: a stop is only sent from an awake, idle intent" do
    stop_box!
    enqueue!
    @client.sandbox = sandbox(state: "archived", stop: stop(status: "completed", requested_at: nil))
    power.reconcile!(@placement)
    @client.sandbox = sandbox(state: "ready", stop: stop(status: "superseded", requested_at: nil))
    @client.on_stop = -> { flunk "no stop after a wake" }

    5.times { power.reconcile!(@placement) }
    assert_equal 1, @client.stops.size
    assert_equal "awake", reload.power_state
  end

  test "a missing or failed box goes to review instead of being woken" do
    enqueue!
    @placement.update!(power_state: "stopped")
    @client.sandbox = nil
    assert_equal :review, power.reconcile!(@placement).outcome
    assert_equal "sandbox_missing", reload.power_review_reason
    assert_empty @client.resumes
  end

  test "an admin clears a review and stops are possible again" do
    @placement.update!(power_review_at: @now, power_review_reason: "stop_unresolved")
    assert_raises(BoatPower::NotAuthorized) { power.clear_power_review!(@placement, requested_by: users(:regular_user)) }
    power.clear_power_review!(@placement, requested_by: @admin)
    assert_not reload.power_review?
    power.request_stop!(@placement, requested_by: @admin)
    assert_equal "stopping", reload.power_state
  end

  test "placements that are not ready Boat boxes are left alone" do
    @placement.update!(state: "retired")
    assert_equal :not_powered, power.reconcile!(@placement).outcome
    assert_raises(BoatPower::NotAllowed) { power.request_stop!(@placement, requested_by: @admin) }
  end

  test "the job keeps checking while a wake waits, honours Retry-After, and stops checking when settled" do
    BoatPower.stub(:from_credentials, power) do
      enqueue!
      @client.sandbox = sandbox(state: "ready")
      assert_enqueued_with(job: BoatPowerJob, args: [ @placement.id ]) { BoatPowerJob.perform_now(@placement.id) }

      heartbeat!(0)
      assert_no_enqueued_jobs(only: BoatPowerJob) { BoatPowerJob.perform_now(@placement.id) }

      @placement.update!(power_state: "stopped")
      enqueue!
      @client.sandbox = sandbox(state: "archived")
      @client.on_resume = -> { raise BoatClient::CapacityUnavailable.new("Boat rate_limited (HTTP 429)", status: 429, code: "rate_limited", retry_after: 90) }
      freeze_time do
        assert_enqueued_with(job: BoatPowerJob, at: 90.seconds.from_now) { BoatPowerJob.perform_now(@placement.id) }
      end
    end
  end

end
