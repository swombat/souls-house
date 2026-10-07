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
# * an empty discovery is not proof of absence; only an operator closes a
#   purchase that might exist
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
        rails_url: "https://#{ENV.fetch("SOULSHOUSE_DOMAIN", "souls.house")}"
      )
    end
  end

  ADMISSION_LOCK = 0x50c5_191

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

      enrollment, token = @minter.mint!(placement: operation.agent_placement, operation_id: operation.id, now: now)
      # The plaintext token lives only in this local and the request body.
      user_data = @renderer.render(enrollment:, token:, rails_url: @config.rails_url)
      operation.update!(state: "create_in_flight", create_sent_at: now)
      true
    end
    return operation unless claimed

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
    rescue HetznerCloudClient::Refused, HetznerCloudClient::NotConfigured, HetznerCloudClient::CapacityUnavailable => e
      refuse!(operation, enrollment, e.code)
    rescue HetznerCloudClient::Error => e
      if e.status.to_i.between?(400, 499)
        # Hetzner validates before it creates: a 4xx bought nothing.
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

  # Operator escape from an unresolved purchase with no server on record, after
  # checking the provider console. Refuses if discovery can see any server.
  def close_without_server!(operation, requested_by:, reason:)
    require_admin!(requested_by)
    raise NotAllowed, "a reason is required" if reason.to_s.strip.length < 10
    unless %w[unknown needs_review create_in_flight].include?(operation.state) && operation.provider_server_id.nil?
      raise NotAllowed, "only an unresolved purchase without a recorded server can be closed"
    end
    raise NotAllowed, "the provider still lists a server for this operation" if @client.find_by_operation(operation.public_id).any?

    operation.with_lock do
      raise NotAllowed, "operation changed; reconcile again" if operation.provider_server_id

      operation.update!(state: "refused", review_reason: "closed by operator: #{reason.to_s.strip}", last_reconciled_at: now)
      operation.runner_enrollment&.revoke!(now:)
    end
    operation
  end

  private

  def now = @clock.call

  def require_admin!(user)
    raise NotAuthorized, "installation admin required" unless user.is_a?(User) && user.is_site_admin?
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
      next unless %w[create_in_flight unknown].include?(operation.state)

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

    action = operation.create_action_id && @client.find_action(operation.create_action_id)
    if action&.status == "error"
      return settle!(operation, "reconciling", "needs_review", review_reason: "create_action_failed",
        last_error_code: action.error_code)
    end
    return touch!(operation) unless server.status == "running" && action&.status != "running"

    provision!(operation, server)
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
