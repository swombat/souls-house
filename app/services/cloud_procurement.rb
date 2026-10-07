# Buys, reconciles and cleans up one Hetzner Cloud server per placement, for
# the installation-admin pilot (#191). No signup, plan enforcement, resident
# moves or scheduler: an admin calls plan!, submit! and reconcile! by hand
# (or through CloudProcurementReconcileJob).
#
# What it protects, and from whom: the house's money from a second order of
# the same server, the house's bookkeeping from a server it has lost track of,
# and residents from a VM being treated as usable before anything has proved
# it can run them. So:
#
# * intent (location, spec, enrollment authority) is committed before HTTP
# * there is exactly one create POST per operation, ever; ambiguity is
#   reconciled against the provider, never retried
# * an empty discovery is not proof of absence, and nothing in the app closes
#   a purchase that might exist: a submitted operation leaves the unresolved
#   set only through a validated provider refusal or verified deletion. No
#   worker, clock or operator action can free its placement for a second order
# * provisioned does not make the placement ready or dispatchable
class CloudProcurement

  class NotAuthorized < StandardError; end
  class NotAllowed < StandardError; end

  Config = Data.define(:image_id, :ssh_key_ids, :locations, :rails_url) do
    def self.from_credentials
      settings = Rails.application.credentials.hetzner_cloud || {}
      new(
        image_id: settings[:image_id].presence && Integer(settings[:image_id]),
        ssh_key_ids: Array(settings[:ssh_key_ids]).map { |id| Integer(id) },
        locations: Array(settings[:allowed_locations]).map(&:to_s),
        # The installation's own domain; no default, so an unset one refuses.
        rails_url: ENV["SOULSHOUSE_DOMAIN"].presence&.then { |domain| "https://#{domain}" }
      )
    end
  end

  ADMISSION_LOCK = 0x50c5_191
  # A claimed submit that has not sent its POST by this deadline never sends
  # it. A stale worker is then stopped before it buys, not reconciled after.
  SUBMIT_DEADLINE = 2.minutes
  # Provider error codes that mean the create was rejected before anything
  # was bought. Anything else, including an unrecognised 4xx, stays unknown.
  REFUSAL_CODES = %w[
    invalid_input json_error forbidden unauthorized token_readonly not_found
    resource_limit_exceeded resource_unavailable placement_error rate_limit_exceeded
  ].freeze

  def self.from_credentials
    new(client: HetznerCloudClient.from_credentials, config: Config.from_credentials)
  end

  def initialize(client:, config:, minter: RunnerEnrollment, renderer: RunnerUserData, clock: -> { Time.current })
    @client = client
    @config = config
    @minter = minter
    @renderer = renderer
    @clock = clock
  end

  # Fixes location and spec for one purchase. Sends nothing.
  def plan!(placement:, requested_by:, approval_reference:, server_type:)
    require_admin!(requested_by)
    raise NotAllowed, "image and SSH keys must be configured" if @config.image_id.nil? || @config.ssh_key_ids.empty?
    raise NotAllowed, "the house domain must be configured" if @config.rails_url.blank?

    CloudProcurementOperation.transaction do
      # Admissions are serialised so concurrent plans see each other's
      # reservations when choosing a location.
      CloudProcurementOperation.connection.execute("SELECT pg_advisory_xact_lock(#{ADMISSION_LOCK})")
      placement.lock!
      unless placement.backend == "hetzner_cloud" && placement.state == "pending" && placement.provider_server_id.nil?
        raise NotAllowed, "placement is not an unprovisioned Hetzner Cloud placement"
      end
      if CloudProcurementOperation.unresolved.exists?(agent_placement_id: placement.id)
        raise NotAllowed, "placement already has an unresolved purchase"
      end

      public_id = "cpo-#{SecureRandom.hex(8)}"
      CloudProcurementOperation.create!(
        agent_placement: placement,
        requested_by:,
        public_id:,
        approval_reference:,
        server_type:,
        location: choose_location,
        image_id: @config.image_id,
        ssh_key_ids: @config.ssh_key_ids,
        provider_name: "souls-house-#{public_id}"
      )
    end
  end

  # Mints enrollment authority, commits create intent, then sends the one
  # create request. Calling it again, concurrently or later, sends nothing.
  def submit!(operation)
    enrollment = nil
    user_data = nil
    claimed = operation.with_lock do
      next false unless operation.state == "planned"

      claimed_at = now
      enrollment, token = @minter.mint!(placement: operation.agent_placement, operation_id: operation.id, now: now)
      # The plaintext token lives only in this local and the request body.
      user_data = @renderer.render(enrollment:, token:, rails_url: @config.rails_url)
      operation.update!(state: "create_in_flight", create_sent_at: claimed_at)
      true
    end
    return operation unless claimed

    # A worker that stalled after its claim does not send a stale POST.
    if now > operation.create_sent_at + SUBMIT_DEADLINE
      settle!(operation, "create_in_flight", "needs_review", review_reason: "submit_deadline_passed")
      return operation.reload
    end

    begin
      created = @client.create_server_with_action(
        name: operation.provider_name,
        placement_id: operation.agent_placement_id.to_s,
        server_type: operation.server_type,
        location: operation.location,
        image: operation.image_id,
        ssh_keys: operation.ssh_key_ids,
        user_data:,
        labels: operation.discovery_labels
      )
    rescue HetznerCloudClient::NameTaken => e
      # Only this operation uses this name, and it only POSTs once.
      settle!(operation, "create_in_flight", "needs_review", last_error_code: e.code, review_reason: "provider_name_taken")
    rescue HetznerCloudClient::CreateOutcomeUnknown => e
      settle!(operation, "create_in_flight", "unknown", last_error_code: e.code)
    rescue HetznerCloudClient::Refused, HetznerCloudClient::NotConfigured => e
      # Raised by the client before any request left this process.
      refuse!(operation, enrollment, e.code)
    rescue HetznerCloudClient::Error => e
      if provider_refusal?(e)
        refuse!(operation, enrollment, e.code)
      else
        settle!(operation, "create_in_flight", "unknown", last_error_code: e.code)
      end
    rescue StandardError
      settle!(operation, "create_in_flight", "unknown", last_error_code: "unexpected_error")
      raise
    else
      record_created!(operation, created)
    end
    operation.reload
  end

  # Compares the operation with what the provider has and moves it at most one
  # step. Safe to run repeatedly and concurrently; never creates anything.
  def reconcile!(operation)
    operation.reload
    case operation.state
    when "create_in_flight", "unknown" then discover!(operation)
    when "reconciling" then check_boot!(operation)
    when "deleting" then check_deletion!(operation)
    end
    operation.reload
  rescue HetznerCloudClient::Error => e
    # A failed or partial read proves nothing; try again later.
    operation.update_columns(last_error_code: e.code, last_reconciled_at: now)
    operation
  end

  # Explicit pilot cleanup. Only a server this operation verified can be
  # deleted; the placement is kept, unavailable, never removed.
  def request_delete!(operation, requested_by:)
    require_admin!(requested_by)
    operation.with_lock do
      unless %w[provisioned reconciling needs_review].include?(operation.state) && operation.provider_server_id
        raise NotAllowed, "only an operation with a verified server can be deleted"
      end

      operation.update!(state: "deleting", delete_requested_at: now, review_reason: nil)
    end
    send_delete!(operation)
    operation.reload
  end

  private

  def now = @clock.call

  def require_admin!(user)
    raise NotAuthorized, "installation admin required" unless user.is_a?(User) && user.is_site_admin?
  end

  # Only a validated provider refusal releases the reservation.
  def provider_refusal?(error)
    error.status.to_i.between?(400, 499) && error.status.to_i != 408 && REFUSAL_CODES.include?(error.code)
  end

  # Least-reserved approved EU location: placements already hosted there plus
  # unresolved purchases still holding a reservation. Ties go to the fixed
  # order, so the same state always picks the same place.
  def choose_location
    candidates = CloudProcurementOperation::EU_LOCATIONS & @config.locations
    raise NotAllowed, "no approved EU location is configured" if candidates.empty?

    holder = AgentPlacement.where(backend: "hetzner_cloud").where.not(location: nil).where.not(state: "retired")
      .pluck(:id, :location).to_h
    CloudProcurementOperation.unresolved.pluck(:agent_placement_id, :location).each do |placement_id, location|
      holder[placement_id] ||= location
    end
    counts = holder.values.tally
    candidates.min_by { |location| [ counts.fetch(location, 0), CloudProcurementOperation::EU_LOCATIONS.index(location) ] }
  end

  # Moves state only if nobody else moved it first.
  def settle!(operation, from, to, **attributes)
    operation.with_lock do
      next false unless operation.state == from

      operation.update!(state: to, last_reconciled_at: now, **attributes)
      true
    end
  end

  def refuse!(operation, enrollment, code)
    operation.with_lock do
      next unless operation.state == "create_in_flight"

      operation.update!(state: "refused", last_error_code: code, last_reconciled_at: now)
      enrollment&.revoke!(now:)
    end
  end

  def record_created!(operation, created)
    server = created.server
    operation.with_lock do
      unless %w[create_in_flight unknown].include?(operation.state)
        # Defence in depth: a server that arrives for an operation no longer
        # waiting for one is recorded, never dropped.
        if operation.provider_server_id.nil?
          operation.update_columns(provider_server_id: server.id, review_reason: "server_arrived_after_close:#{operation.state}",
            last_reconciled_at: now)
          Rails.logger.error("[cloud_procurement] server #{server.id} arrived for #{operation.public_id} in state #{operation.state}")
        end
        next
      end

      unless matches?(operation, server)
        operation.update!(state: "needs_review", provider_server_id: server.id, review_reason: "created_server_mismatch",
          last_reconciled_at: now)
        next
      end

      operation.update!(state: "reconciling", provider_server_id: server.id, create_action_id: created.action_id,
        ipv4: server.ipv4, ipv6: server.ipv6, last_error_code: nil, last_reconciled_at: now)
    end
  end

  def discover!(operation)
    servers = @client.find_by_operation(operation.public_id)
    if servers.size > 1
      settle!(operation, operation.state, "needs_review", review_reason: "multiple_servers_found")
    elsif servers.size == 1
      server = servers.first
      if matches?(operation, server)
        record_created!(operation, HetznerCloudClient::Created.new(server:, action_id: nil, action_status: nil))
      else
        settle!(operation, operation.state, "needs_review", review_reason: "discovered_server_mismatch")
      end
    elsif enrollment_expired?(operation)
      # The token in that request can no longer enroll, and it is never
      # re-minted. A purchase may still exist: an operator decides.
      settle!(operation, operation.state, "needs_review", review_reason: "enrollment_expired_unresolved")
    else
      # Zero matches: still unknown. Not proof that nothing was bought.
      settle!(operation, operation.state, "unknown")
    end
  end

  def check_boot!(operation)
    server = @client.find_server(operation.provider_server_id)
    return settle!(operation, "reconciling", "needs_review", review_reason: "server_missing") if server.nil?
    return settle!(operation, "reconciling", "needs_review", review_reason: "server_mismatch") unless matches?(operation, server)

    return recover_create_action!(operation) if operation.create_action_id.nil?

    action = @client.find_action(operation.create_action_id)
    case action&.status
    when "success"
      server.status == "running" ? provision!(operation, server) : touch!(operation)
    when "running"
      touch!(operation)
    when "error"
      settle!(operation, "reconciling", "needs_review", review_reason: "create_action_failed", last_error_code: action.error_code)
    when nil
      settle!(operation, "reconciling", "needs_review", review_reason: "create_action_missing")
    else
      settle!(operation, "reconciling", "needs_review", review_reason: "create_action_unrecognised")
    end
  end

  # A server found by discovery came without its boot action id. Recover it
  # from the server's own history; boot is never inferred from status alone.
  def recover_create_action!(operation)
    actions = @client.create_actions_for(operation.provider_server_id)
    unless actions.size == 1 && actions.first.command == "create_server"
      return settle!(operation, "reconciling", "needs_review", review_reason: "create_action_unverifiable")
    end

    operation.update_columns(create_action_id: actions.first.id, last_reconciled_at: now)
  end

  # The provider confirms the server; the runner may now enroll. The placement
  # learns where it lives but stays pending: provisioned is not ready.
  def provision!(operation, server)
    operation.with_lock do
      next unless operation.state == "reconciling"

      enrollment = operation.runner_enrollment
      if enrollment.nil? || enrollment.revoked_at || now >= enrollment.expires_at
        operation.update!(state: "needs_review", review_reason: "enrollment_unusable", last_reconciled_at: now)
        next
      end

      enrollment.confirm_provider_server!(server.id)
      operation.agent_placement.update!(location: operation.location, provider_server_id: server.id)
      operation.update!(state: "provisioned", provisioned_at: now, ipv4: server.ipv4, ipv6: server.ipv6,
        last_reconciled_at: now)
    end
  end

  def send_delete!(operation)
    result = @client.delete_server(operation.provider_server_id, placement_id: operation.agent_placement_id.to_s)
    if result.is_a?(HetznerCloudClient::DeleteAccepted)
      operation.update_columns(delete_action_id: result.action_id, last_reconciled_at: now)
    end
    check_deletion!(operation, resend: false)
  rescue HetznerCloudClient::Refused => e
    settle!(operation, "deleting", "needs_review", review_reason: "delete_refused", last_error_code: e.code)
  rescue HetznerCloudClient::Error => e
    # Lost or failed response: the server may or may not be going. Reconcile.
    operation.update_columns(last_error_code: e.code, last_reconciled_at: now)
  end

  # A lost or failed delete is sent again on a later pass, never in a loop.
  def check_deletion!(operation, resend: true)
    server = @client.find_server(operation.provider_server_id)
    if server
      action = operation.delete_action_id && @client.find_action(operation.delete_action_id)
      if resend && (operation.delete_action_id.nil? || action.nil? || action.status == "error")
        return send_delete!(operation)
      end

      return touch!(operation)
    end

    operation.with_lock do
      next unless operation.state == "deleting"

      placement = operation.agent_placement
      if placement.provider_server_id == operation.provider_server_id
        placement.update!(provider_server_id: nil, location: nil)
      end
      operation.runner_enrollment&.revoke!(now:)
      operation.update!(state: "deleted", deleted_at: now, last_reconciled_at: now)
    end
  end

  def touch!(operation)
    operation.update_columns(last_reconciled_at: now)
  end

  # Intent and enrollment commit together, so a missing enrollment is as
  # unusable as an expired one.
  def enrollment_expired?(operation)
    enrollment = operation.runner_enrollment
    enrollment.nil? || now >= enrollment.expires_at
  end

  # Identity and spec, not just a name.
  def matches?(operation, server)
    server.managed? &&
      server.placement_id == operation.agent_placement_id.to_s &&
      server.operation_id == operation.public_id &&
      server.name == operation.provider_name &&
      server.server_type == operation.server_type &&
      server.location == operation.location &&
      server.image_id == operation.image_id
  end

end
