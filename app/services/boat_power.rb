# Wakes and stops one Boat placement's sandbox (slice 2, PR 3, ePokyY).
#
# Every local transition is a compare-and-set on (power_epoch, power_state),
# committed before any HTTP call. Every provider outcome is read back from
# the sandbox before the house trusts it.
#
# Stop. Boat's stop takes only `force` (never sent): no idempotency key, no
# conditional form, so a stop request cannot be fenced at Boat. The house
# fences its own workers instead. A stop intent bumps the epoch and commits
# `stopping`; a worker may send only after winning
#   stop_sent_at := now WHERE epoch = E AND stopping AND stop_sent_at IS NULL
#     AND no wake is pending AND no review
# so a worker that paused before winning sends nothing. A worker that pauses
# after winning and before its POST cannot be fenced. So a stop is resolved
# only by affirmative evidence:
#   * the POST got an HTTP answer: Boat processed it, and it cannot land
#     later; the stop id it returned is recorded under the epoch, or
#   * the sandbox now names a stop other than the last one recorded, and
#     that stop, read by id, was accepted no earlier than stop_sent_at
#     (less CLOCK_SKEW).
# A stop with neither (a timeout, a 5xx, an answer lost to a restart before
# it was written down and no matching stop on the sandbox) puts the placement
# in power review: every stop is off for it until an operator clears it.
# Time passing resolves nothing: there is no return to awake and no resend.
# A failing stop is live (Boat retries it). force is never sent.
#
# Wake. Every command enqueued for the placement bumps wake_request_version
# (in the enqueue's transaction) and kicks BoatPowerJob. A resume is sent
# only after a read shows the sandbox archived, archiving or holding a live
# stop; what resume does to an awake sandbox is not documented. A wake intent
# bumps the epoch. The wake is satisfied only by a heartbeat stamped with the
# current epoch (the runner learns it from the heartbeat response; a warm
# resume need not reboot) while the house has read the sandbox awake, and
# then only up to the request version read in the same statement.
#
# A wake still goes through while a placement is in review. The risk that
# leaves is named, not hidden: an unresolved stop could land on the woken
# box. It would interrupt a turn, not lose the disk (Boat saves it first),
# and the next pending wake reads the box archived and resumes it.
#
# No idle stop here. Until the quiescence protocol (PR 5), a Boat box stops
# only when an operator asks (request_stop!), under the same protocol.
class BoatPower

  class NotAuthorized < StandardError; end
  class NotAllowed < StandardError; end

  # How far Boat's clock may run behind ours when matching a stop's
  # requestedAt to our stop_sent_at.
  CLOCK_SKEW = 10.seconds
  # Waits used by BoatPowerJob when Boat gives no Retry-After.
  RECHECK = 30.seconds
  REVIEW_RECHECK = 5.minutes
  LIVE_COMMAND_STATES = %w[queued delivered].freeze

  Result = Data.define(:outcome, :retry_after) do
    def initialize(outcome:, retry_after: nil) = super
  end

  def self.from_credentials = new(client: BoatClient.from_credentials)

  # Call inside the transaction that enqueues a command for the placement.
  # Kicks the job only when this request is the first one waiting: the job
  # keeps checking while any wake is pending, so one chain is enough.
  def self.request_wake!(placement)
    return unless placement.boat?

    scope = AgentPlacement.where(id: placement.id)
    scope.update_all([ "wake_request_version = wake_request_version + 1, updated_at = ?", Time.current ])
    requested, satisfied = scope.pick(:wake_request_version, :wake_satisfied_version)
    BoatPowerJob.perform_later(placement.id) if requested - satisfied == 1
  end

  # The heartbeat answer tells a Boat runner the epoch to stamp on its next
  # heartbeat. Nil for other backends.
  def self.heartbeat_answer(placement)
    placement&.boat? ? { "power_epoch" => placement.power_epoch } : {}
  end

  # A heartbeat stamped with the current epoch, while the house has read the
  # sandbox awake, satisfies every wake requested up to now. One statement,
  # so the version it clears is the one it read.
  def self.observe_heartbeat!(placement, facts)
    return false unless placement&.boat?

    epoch = facts.is_a?(Hash) ? facts["power_epoch"] : nil
    return false unless epoch.is_a?(Integer)

    AgentPlacement.where(id: placement.id, power_state: "awake", power_epoch: epoch)
      .where("wake_satisfied_version < wake_request_version")
      .update_all([ "wake_satisfied_version = wake_request_version, updated_at = ?", Time.current ]) == 1
  end

  def initialize(client:, clock: -> { Time.current })
    @client = client
    @clock = clock
  end

  # An installation admin asks for this placement's box to stop. Commits the
  # intent only; BoatPowerJob sends it.
  def request_stop!(placement, requested_by:)
    require_admin!(requested_by)
    AgentPlacement.transaction do
      placement.lock!
      raise NotAllowed, "not a ready Boat placement" unless powered?(placement)
      raise NotAllowed, "placement is in power review" if placement.power_review?
      raise NotAllowed, "placement is #{placement.power_state}, not awake" unless placement.power_state == "awake"
      raise NotAllowed, "a wake is pending" if placement.wake_pending?
      if RunnerCommand.where(agent_placement_id: placement.id, state: LIVE_COMMAND_STATES).exists?
        raise NotAllowed, "the runner has a command in flight"
      end

      placement.update!(power_state: "stopping", power_epoch: placement.power_epoch + 1, stop_sent_at: nil,
        power_changed_at: now)
    end
    BoatPowerJob.perform_later(placement.id)
    placement
  end

  # An installation admin, having looked at the box, turns stops back on.
  def clear_power_review!(placement, requested_by:)
    require_admin!(requested_by)
    placement.with_lock { placement.update!(power_review_at: nil, power_review_reason: nil) }
  end

  # One step for one placement. Never sends a stop without winning the
  # compare-and-set, never resumes without a read first.
  def reconcile!(placement)
    placement = AgentPlacement.find(placement.id)
    return Result.new(outcome: :not_powered) unless powered?(placement)

    case placement.power_state
    when "stopping"
      placement.stop_sent_at.nil? ? send_or_cancel_stop!(placement) : settle_stop!(placement)
    when "waking"
      wake!(placement)
    else
      placement.wake_pending? ? wake!(placement) : Result.new(outcome: :idle)
    end
  end

  private

  def powered?(placement)
    placement.boat? && placement.state == "ready" && placement.provider_sandbox_id.present?
  end

  def send_or_cancel_stop!(placement)
    epoch = placement.power_epoch
    stopping = AgentPlacement.where(id: placement.id, power_epoch: epoch, power_state: "stopping", stop_sent_at: nil)
    won = stopping.where(power_review_at: nil).where("wake_satisfied_version = wake_request_version")
      .update_all(stop_sent_at: now, updated_at: now) == 1
    unless won
      # Nothing was sent under this epoch: a wake or a review arrived first.
      cancelled = stopping.update_all(power_state: "awake", power_epoch: epoch + 1, power_changed_at: now,
        updated_at: now) == 1
      return Result.new(outcome: cancelled ? :stop_cancelled : :superseded)
    end

    send_stop!(placement, epoch)
  end

  def send_stop!(placement, epoch)
    accepted = @client.stop_sandbox(placement.provider_sandbox_id, placement_id: placement.id)
    # Answered: Boat processed this request, so it cannot land later.
    record_stop!(placement, epoch, accepted.stop.id)
    settle_stop!(placement.reload)
  rescue BoatClient::Error => e
    if unanswered?(e)
      settle_stop!(placement.reload)
    else
      # Refused with an answer (or by the client before sending): no stop
      # will land. The box was never stopped by this request.
      back_to_awake!(placement, epoch, review: "stop_refused_#{e.code}")
    end
  end

  def settle_stop!(placement)
    return Result.new(outcome: :superseded) unless placement.power_state == "stopping"

    sandbox = @client.find_sandbox(placement.provider_sandbox_id)
    return review!(placement, "sandbox_missing") if sandbox.nil?

    stop_id = placement.stop_epoch == placement.power_epoch ? placement.stop_id : discovered_stop_id(placement, sandbox)
    if stop_id.nil?
      review!(placement, "stop_unresolved")
      return placement.reload.wake_pending? ? wake!(placement, sandbox:) : Result.new(outcome: :stop_unresolved)
    end

    record_stop!(placement, placement.power_epoch, stop_id)
    clear_unresolved!(placement)
    if sandbox.stopped?
      move!(placement, "stopping", "stopped")
      placement.reload.wake_pending? ? wake!(placement, sandbox:) : Result.new(outcome: :stopped)
    elsif sandbox.live_stop?
      placement.reload.wake_pending? ? wake!(placement, sandbox:) : Result.new(outcome: :stopping)
    else
      # Our stop ended without archiving the box: someone else resumed it.
      back_to_awake!(placement, placement.power_epoch, review: "stop_ended_elsewhere")
    end
  end

  def discovered_stop_id(placement, sandbox)
    candidate = sandbox.stop
    return nil if candidate.nil? || candidate.id == placement.stop_id || placement.stop_sent_at.nil?

    stop = @client.find_stop(placement.provider_sandbox_id, candidate.id)
    return nil if stop&.requested_at.nil?

    stop.requested_at >= placement.stop_sent_at - CLOCK_SKEW ? stop.id : nil
  end

  def wake!(placement, sandbox: nil)
    sandbox ||= @client.find_sandbox(placement.provider_sandbox_id)
    return review!(placement, "sandbox_missing") if sandbox.nil?
    return review!(placement, "sandbox_failed") if sandbox.failed?

    if sandbox.awake? && !sandbox.live_stop?
      # Out of stopping (a stop we could not resolve), a new epoch: only a
      # heartbeat answered after this read can satisfy the wake. Out of
      # waking, the epoch is already the wake's own.
      move!(placement, placement.power_state, "awake", bump: placement.power_state != "waking") unless placement.power_state == "awake"
      return Result.new(outcome: :awake)
    end
    return resume!(placement) if sandbox.stopped? || sandbox.live_stop?

    Result.new(outcome: :settling)
  end

  def resume!(placement)
    epoch = placement.power_epoch
    claimed = AgentPlacement.where(id: placement.id, power_epoch: epoch, power_state: placement.power_state)
      .update_all(power_state: "waking", power_epoch: epoch + 1, power_changed_at: now, updated_at: now) == 1
    return Result.new(outcome: :superseded) unless claimed

    @client.resume_sandbox(placement.provider_sandbox_id, placement_id: placement.id)
    Result.new(outcome: :waking)
  rescue BoatClient::SandboxStopping, BoatClient::CapacityUnavailable => e
    Result.new(outcome: :wake_deferred, retry_after: e.retry_after&.seconds)
  rescue BoatClient::SnapshotExpired
    review!(placement, "snapshot_expired")
  rescue BoatClient::NotFound
    review!(placement, "sandbox_missing")
  rescue BoatClient::Error
    # Unknown: the next step reads the box before doing anything else.
    Result.new(outcome: :waking)
  end

  # No HTTP answer, or a server-side failure: the request may still land.
  def unanswered?(error)
    error.code == "unavailable" || error.status.to_i >= 500 || error.status.to_i == 408
  end

  def record_stop!(placement, epoch, stop_id)
    AgentPlacement.where(id: placement.id, power_epoch: epoch, power_state: "stopping")
      .update_all(stop_id:, stop_epoch: epoch, updated_at: now)
  end

  def move!(placement, from, to, bump: false)
    epoch = placement.power_epoch
    AgentPlacement.where(id: placement.id, power_epoch: epoch, power_state: from)
      .update_all(power_state: to, power_epoch: bump ? epoch + 1 : epoch, power_changed_at: now, updated_at: now) == 1
  end

  def back_to_awake!(placement, epoch, review:)
    AgentPlacement.where(id: placement.id, power_epoch: epoch, power_state: "stopping")
      .update_all(power_state: "awake", power_epoch: epoch + 1, power_changed_at: now, updated_at: now)
    review!(placement, review)
  end

  def review!(placement, reason)
    flagged = AgentPlacement.where(id: placement.id, power_review_at: nil)
      .update_all(power_review_at: now, power_review_reason: reason.to_s.first(64), updated_at: now) == 1
    Rails.logger.warn("[BoatPower] placement #{placement.id} in power review: #{reason}") if flagged
    Result.new(outcome: :review)
  end

  # Evidence for the stop arrived after all: the review it caused is over.
  def clear_unresolved!(placement)
    AgentPlacement.where(id: placement.id, power_review_reason: "stop_unresolved")
      .update_all(power_review_at: nil, power_review_reason: nil, updated_at: now)
  end

  def require_admin!(user)
    raise NotAuthorized, "installation admin required" unless user.is_a?(User) && user.is_site_admin?
  end

  def now = @clock.call

end
