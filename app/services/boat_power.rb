# Wakes one Boat placement's sandbox before work reaches it (slice 2, PR 3,
# ePokyY).
#
# There is no stop here, not even an admin one. A Boat stop takes no
# idempotency key and no condition, so a worker that pauses after deciding
# to stop and before its POST cannot be fenced, and its stop can archive a
# box whose wake was already satisfied. The stop protocol comes with the
# quiescence work (PR 5), designed around that interleaving. Until then the
# house never stops a Boat box (create and resume send ttlSeconds: null, so
# Boat does not either). This class only brings back a box something else
# stopped, before the command waiting for it is delivered.
#
# Every local transition is a compare-and-set on (power_epoch, power_state).
# Every command enqueued for the placement bumps wake_request_version in the
# enqueue's transaction, and the first waiting request kicks BoatPowerJob
# once that transaction has committed. A resume is sent only after a read
# shows the sandbox archived, archiving or holding a live stop; what resume
# does to an awake sandbox is not documented. A wake bumps the epoch. The
# wake is satisfied only by a heartbeat stamped with the current epoch (the
# runner learns it from the heartbeat response; a warm resume need not
# reboot) while the house has read the sandbox awake, and then only up to
# the request version read in the same statement.
class BoatPower

  class NotAuthorized < StandardError; end

  # Waits used by BoatPowerJob when Boat gives no Retry-After.
  RECHECK = 30.seconds

  Result = Data.define(:outcome, :retry_after) do
    def initialize(outcome:, retry_after: nil) = super
  end

  def self.from_credentials = new(client: BoatClient.from_credentials)

  # Call inside the transaction that enqueues a command for the placement.
  # Kicks the job only when this request is the first one waiting (the job
  # keeps checking while any wake is pending, so one chain is enough), and
  # only after the enqueue commits: the queue lives in another database, so
  # a job enqueued inside the transaction could run, read no pending wake and
  # end before the command it is for exists. A rollback kicks nothing.
  def self.request_wake!(placement)
    return unless placement.boat?

    scope = AgentPlacement.where(id: placement.id)
    # The first waiting request also moves the epoch on, so a heartbeat
    # stamped before it (one delayed from a box that has since stopped)
    # cannot satisfy it: only a runner that heard the new epoch in a
    # heartbeat answer after this request can.
    scope.update_all([ <<~SQL.squish, Time.current ])
      wake_request_version = wake_request_version + 1,
      power_epoch = CASE WHEN wake_request_version = wake_satisfied_version THEN power_epoch + 1 ELSE power_epoch END,
      updated_at = ?
    SQL
    requested, satisfied = scope.pick(:wake_request_version, :wake_satisfied_version)
    return unless requested - satisfied == 1

    placement_id = placement.id
    ActiveRecord.after_all_transactions_commit { BoatPowerJob.perform_later(placement_id) }
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

  # An installation admin, having looked at the box, clears its review.
  def clear_power_review!(placement, requested_by:)
    require_admin!(requested_by)
    placement.with_lock { placement.update!(power_review_at: nil, power_review_reason: nil) }
    BoatPowerJob.perform_later(placement.id) if placement.wake_pending? || placement.power_state == "waking"
    placement
  end

  # One step for one placement. Never resumes without a read first.
  def reconcile!(placement)
    placement = AgentPlacement.find(placement.id)
    return Result.new(outcome: :not_powered) unless powered?(placement)
    return wake!(placement) if placement.power_state == "waking" || placement.wake_pending?

    Result.new(outcome: :idle)
  end

  private

  def powered?(placement)
    placement.boat? && placement.state == "ready" && placement.provider_sandbox_id.present?
  end

  def wake!(placement)
    sandbox = @client.find_sandbox(placement.provider_sandbox_id)
    return review!(placement, "sandbox_missing") if sandbox.nil?
    return review!(placement, "sandbox_failed") if sandbox.failed?

    if sandbox.awake? && !sandbox.live_stop?
      # Out of waking the epoch is already the wake's own: only a heartbeat
      # answered after the resume can carry it.
      move!(placement, "waking", "awake") if placement.power_state == "waking"
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

  def move!(placement, from, to)
    epoch = placement.power_epoch
    AgentPlacement.where(id: placement.id, power_epoch: epoch, power_state: from)
      .update_all(power_state: to, power_changed_at: now, updated_at: now) == 1
  end

  def review!(placement, reason)
    flagged = AgentPlacement.where(id: placement.id, power_review_at: nil)
      .update_all(power_review_at: now, power_review_reason: reason.to_s.first(64), updated_at: now) == 1
    Rails.logger.warn("[BoatPower] placement #{placement.id} in power review: #{reason}") if flagged
    Result.new(outcome: :review)
  end

  def require_admin!(user)
    raise NotAuthorized, "installation admin required" unless user.is_a?(User) && user.is_site_admin?
  end

  def now = @clock.call

end
