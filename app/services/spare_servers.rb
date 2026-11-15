# Buys Hetzner servers before a resident needs them (eRyZBY, Daniel
# 2026-11-15). The larger shared types are on sale for a few minutes at a
# time (CX33: 24 of 599 five-minute checks over three days), so no person
# catches a window. Each availability check calls replenish! with what
# Hetzner just said, and it orders what is missing:
#
#   wanted for a type = residents waiting for that type + the type's spare target
#   missing           = wanted - spares of that type already held or on order
#
# A resident is waiting when it runs on its own server, its plan in force
# names a bigger machine than the one it is on, and nothing has asked for its
# server to go. A spare already held or on order includes every purchase that
# might exist: planned, in flight, unknown, needing review. Only one settled
# as refused or deleted stops counting, so a check can't buy the same server
# twice.
#
# What it protects, and from whom: the house's money, from a loop. Every
# order is one CloudProcurementOperation (one create request, ever), planned
# under the procurement admission lock with the count taken under that lock,
# and the total of spares that might exist never passes the cap in Site
# Admin. The cap and the targets are 0 until a site admin sets them, so an
# installation that never asked for this buys nothing.
#
# Any approved EU location will do: a resident moves onto a spare by having
# its disk copied there, wherever it runs today, so a spare has no location
# to match beyond the house's allowlist.
#
# Hetzner's "available" flag is neither a promise nor a verdict. A refused
# order is settled as refused and that type and location are left alone for a
# while. And an order can succeed while the flag says no: on 2026-11-15 the
# flag had CX23 and CX33 unavailable in every location for half an hour, and
# in that half hour the house bought one of each. So when the house is short
# of a type and no location is flagged, it still tries one location per
# check, the one tried longest ago. A refusal costs nothing.
#
# One refusal is different: resource_limit_exceeded is the Hetzner project's
# own limit on servers, not stock. No location will do better, so for
# LIMIT_PAUSE no order is sent at all, new or left planned, and Site Admin
# says why. Purchases already sent are still reconciled.
class SpareServers

  # After a refusal, the same type in the same location is not tried again
  # for this long, so a window that lies costs one order, not one per check.
  REFUSAL_PAUSE = 20.minutes
  # After the project's server limit refused an order, nothing is ordered for
  # this long: only a person (or a released server) changes that answer.
  LIMIT_PAUSE = 1.hour
  PROJECT_LIMIT_CODE = "resource_limit_exceeded".freeze
  # The reconcile job re-queues itself every minute while a purchase settles.
  # A settling spare nobody has reconciled for this long has lost its job.
  RECONCILE_STALE_AFTER = 3.minutes
  TYPES = CloudProcurementOperation::SERVER_TYPES

  def self.replenish!(availability)
    new.replenish!(availability)
  end

  def initialize(setting: Setting.instance, procurement: nil, clock: -> { Time.current })
    @setting = setting
    @procurement = procurement
    @clock = clock
  end

  # availability is HetznerCloudClient#server_type_availability. Returns the
  # operations it submitted. Never raises for a provider failure: the next
  # check is five minutes away.
  def replenish!(availability)
    recover!
    return [] unless @setting.reload.spare_server_limit.positive?

    planned = plan!(availability)
    planned.each { |operation| submit(operation) }
    planned
  rescue CloudProcurement::NotAllowed, HetznerCloudClient::Error => e
    Rails.logger.error("[spare_servers] nothing ordered: #{e.class}: #{e.message}")
    []
  end

  # Picks up what a stopped worker left (Mira, #977). Runs on every check,
  # whatever the limit says now, because these purchases already hold a slot:
  #
  # - a spare still planned was counted and never sent. submit! sends its one
  #   request now, or does nothing if another worker has claimed it. If its
  #   location has sold out, Hetzner refuses it and the slot is free again.
  # - a spare left settling (sent or maybe sent, booting, deleting) with no
  #   recent reconcile gets its reconcile job again. That only reads the
  #   provider: an uncertain purchase is never sent a second time.
  def recover!
    # While the project's server limit rests all buying, a planned spare is
    # not sent either: it would be refused for the same reason and extend
    # the rest. It keeps its slot and is sent when the rest is over.
    unless project_limit_hit_at
      CloudProcurementOperation.spares.where(state: "planned").order(:id).each { |operation| submit(operation) }
    end
    CloudProcurementOperation.spares.where(state: CloudProcurementReconcileJob::SETTLING_STATES)
      .where("last_reconciled_at IS NULL OR last_reconciled_at < ?", now - RECONCILE_STALE_AFTER)
      .where(updated_at: ..(now - RECONCILE_STALE_AFTER))
      .order(:id).each { |operation| CloudProcurementReconcileJob.perform_later(operation.id) }
  rescue StandardError => e
    Rails.logger.error("[spare_servers] recovery failed: #{e.class}: #{e.message}")
  end

  # What Site Admin shows: per type, who is waiting, the target, what is held
  # or on order; and the cap.
  def status
    held = CloudProcurementOperation.spares.unresolved.group(:server_type).count
    {
      limit: @setting.spare_server_limit,
      counted: held.values.sum,
      project_limit_hit_at: project_limit_hit_at&.iso8601,
      types: TYPES.map do |type|
        { server_type: type, waiting: waiting(type), target: target(type), held: held.fetch(type, 0) }
      end,
      servers: CloudProcurementOperation.spares.unresolved.order(:id).map do |operation|
        { public_id: operation.public_id, server_type: operation.server_type, location: operation.location,
          state: operation.state, since: (operation.provisioned_at || operation.created_at).iso8601 }
      end
    }
  end

  # Residents on their own server whose plan names this type and whose
  # server is a smaller one.
  def waiting(type)
    rank = TYPES.index(type)
    tiers = Billing::Tier.all.select { |tier| tier.server_type == type }.map(&:id)
    return 0 if rank.nil? || tiers.empty?

    smaller = TYPES.first(rank)
    AgentPlacement.where(backend: "hetzner_cloud", state: "ready", cleanup_requested_at: nil)
      .where(agent_id: ResidentEntitlement.where(tier: tiers, state: Billing::Tier::IN_FORCE_STATES).select(:agent_id))
      .where(id: CloudProcurementOperation.where(purpose: "placement", state: "provisioned", server_type: smaller)
        .select(:agent_placement_id))
      .count
  end

  private

  def now = @clock.call

  # One create request for one planned spare, then its reconcile job. A
  # failure here leaves the purchase recorded (unknown, or still planned) for
  # the next check's recover!.
  def submit(operation)
    procurement.submit!(operation)
    CloudProcurementReconcileJob.set(wait: 30.seconds).perform_later(operation.id)
  rescue StandardError => e
    Rails.logger.error("[spare_servers] submit #{operation.public_id} failed: #{e.class}")
  end

  def procurement
    @procurement ||= CloudProcurement.from_credentials
  end

  def target(type) = @setting.public_send("spare_#{type}_target")

  # Counts and plans in one transaction under the admission lock, so two
  # checks running together see each other's orders.
  def plan!(availability)
    CloudProcurementOperation.transaction do
      CloudProcurementOperation.connection.execute("SELECT pg_advisory_xact_lock(#{CloudProcurement::ADMISSION_LOCK})")
      limit = @setting.reload.spare_server_limit
      next [] if project_limit_hit_at

      held = CloudProcurementOperation.spares.unresolved.group(:server_type).count
      room = limit - held.values.sum

      TYPES.flat_map do |type|
        missing = waiting(type) + target(type) - held.fetch(type, 0)
        places, flagged = locations_selling(type, availability)
        count = [ missing, room ].min
        # A try against the flag is one order, whatever is missing: it is a
        # question put to Hetzner, not a batch (Mira, #980).
        count = [ count, 1 ].min unless flagged
        next [] if count <= 0 || places.empty?

        room -= count
        Array.new(count) do |index|
          operation = procurement.plan_spare!(server_type: type, location: places[index % places.size],
            approval_reference: "setting:spare_servers/#{type}")
          AuditLog.create!(action: "spare_server_ordered", auditable: operation,
            data: { "server_type" => type, "location" => operation.location, "waiting" => waiting(type),
                    "target" => target(type), "held_before" => held.fetch(type, 0), "limit" => limit })
          operation
        end
      end
    end
  end

  # Where to order a type now, and whether Hetzner flagged it: the allowed
  # locations Hetzner flags as selling it, or, when it flags none, the one
  # allowed location tried longest ago (never, first). Either way a location that refused a spare of
  # this type a short while ago is left out. Filtered here, before anything
  # is planned: a location plan_spare! would refuse must not roll back the
  # orders beside it.
  def locations_selling(type, availability)
    recent = CloudProcurementOperation.spares.where(server_type: type, state: "refused")
    paused = recent.where(updated_at: (now - REFUSAL_PAUSE)..).distinct.pluck(:location)
    allowed = procurement.spare_locations - paused
    places = availability[type]
    flagged = places.is_a?(Hash) ? allowed.select { |location| places[location] == true } : []
    return [ flagged, true ] if flagged.any?

    last_tried = CloudProcurementOperation.spares.where(server_type: type).group(:location).maximum(:created_at)
    [ allowed.min_by(1) { |location| [ last_tried[location] || Time.at(0), allowed.index(location) ] }, false ]
  end

  # When the Hetzner project's server limit last refused a spare, if that
  # was within LIMIT_PAUSE.
  def project_limit_hit_at
    CloudProcurementOperation.spares.where(state: "refused", last_error_code: PROJECT_LIMIT_CODE)
      .where(updated_at: (now - LIMIT_PAUSE)..).maximum(:updated_at)
  end

end
