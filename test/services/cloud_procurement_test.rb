require "test_helper"

class CloudProcurementTest < ActiveSupport::TestCase

  IMAGE_ID = 161_547_269

  # Stands in for HetznerCloudClient. Records every call; behaviour per call
  # is set by the test. Nothing here talks to the network.
  class FakeClient

    attr_reader :creates, :deletes
    attr_accessor :on_create, :servers, :actions, :on_delete, :on_list, :create_actions

    def initialize
      @creates = []
      @deletes = []
      @servers = {}
      @actions = {}
    end

    def create_server_with_action(**kwargs)
      @creates << kwargs
      on_create.call(kwargs)
    end

    def find_server(id)
      servers[id]
    end

    def find_by_operation(public_id)
      return on_list.call(public_id) if on_list

      servers.values.select { |server| server.operation_id == public_id }
    end

    def find_action(id)
      actions[id]
    end

    def create_actions_for(server_id)
      (create_actions || {}).fetch(server_id, [])
    end

    def delete_server(id, placement_id:)
      @deletes << [ id, placement_id ]
      on_delete ? on_delete.call(id) : HetznerCloudClient::DeleteAccepted.new(server_id: id, action_id: 900 + @deletes.size, action_status: "running")
    end

  end

  setup do
    @admin = users(:site_admin_user)
    @client = FakeClient.new
    @now = Time.zone.parse("2026-10-07 20:00:00")
    @config = CloudProcurement::Config.new(image_id: IMAGE_ID, ssh_key_ids: [ 101 ], locations: %w[fsn1 nbg1 hel1],
      rails_url: "https://souls.example")
    @placement = AgentPlacement.create!(agent: agents(:research_assistant), backend: "hetzner_cloud", state: "pending")
  end

  def service(clock: -> { @now })
    CloudProcurement.new(client: @client, config: @config, clock:)
  end

  def plan!(placement: @placement)
    service.plan!(placement:, requested_by: @admin, approval_reference: "souls.house KjXOAe/YkaQnj", server_type: "cx23")
  end

  def server_for(operation, id: 4242, status: "running", **overrides)
    labels = { HetznerCloudClient::MANAGED_LABEL => "true", HetznerCloudClient::PLACEMENT_LABEL => operation.agent_placement_id.to_s,
               HetznerCloudClient::OPERATION_LABEL => operation.public_id }
    HetznerCloudClient::Server.new(**{ id:, name: operation.provider_name, status:, server_type: operation.server_type,
                                       location: operation.location, image_id: operation.image_id, ipv4: "203.0.113.9",
                                       ipv6: "2001:db8::/64", labels: }.merge(overrides))
  end

  def action(id, status, command: "create_server", error_code: nil)
    HetznerCloudClient::Action.new(id:, command:, status:, error_code:)
  end

  def created_for(operation, **)
    server = server_for(operation, status: "initializing", **)
    @client.servers[server.id] = server
    HetznerCloudClient::Created.new(server:, action_id: 77, action_status: "running")
  end

  # --- admission ---------------------------------------------------------

  test "only an installation admin can plan a purchase" do
    assert_raises(CloudProcurement::NotAuthorized) do
      service.plan!(placement: @placement, requested_by: users(:regular_user), approval_reference: "x", server_type: "cx23")
    end
    assert_raises(CloudProcurement::NotAuthorized) do
      service.plan!(placement: @placement, requested_by: nil, approval_reference: "x", server_type: "cx23")
    end
    assert_equal 0, CloudProcurementOperation.count
  end

  test "planning fixes location and spec and sends nothing" do
    operation = plan!

    assert_equal "planned", operation.state
    assert_equal "fsn1", operation.location
    assert_equal IMAGE_ID, operation.image_id
    assert_equal [ 101 ], operation.ssh_key_ids
    assert_match(/\Asouls-house-cpo-[0-9a-f]{16}\z/, operation.provider_name)
    assert_empty @client.creates
    assert_nil operation.runner_enrollment
  end

  test "refuses local, ready or already-provisioned placements and missing configuration" do
    local = AgentPlacement.create!(agent: agents(:code_reviewer), backend: "local", state: "ready")
    assert_raises(CloudProcurement::NotAllowed) { plan!(placement: local) }

    @placement.update!(provider_server_id: 55)
    assert_raises(CloudProcurement::NotAllowed) { plan! }
    @placement.update!(provider_server_id: nil)

    @config = @config.with(ssh_key_ids: [])
    assert_raises(CloudProcurement::NotAllowed) { plan! }
    @config = @config.with(ssh_key_ids: [ 101 ], locations: %w[ash])
    assert_raises(CloudProcurement::NotAllowed) { plan! }
    assert_equal 0, CloudProcurementOperation.count
  end

  test "one unresolved purchase per placement, in the service and in the database" do
    first = plan!
    assert_raises(CloudProcurement::NotAllowed) { plan! }

    duplicate = first.dup
    duplicate.public_id = "cpo-duplicate"
    duplicate.provider_name = "souls-house-cpo-duplicate"
    assert_raises(ActiveRecord::RecordNotUnique) { duplicate.save!(validate: false) }

    first.update!(state: "refused")
    assert plan!.persisted?
  end

  test "least-reserved location counts placements and unresolved reservations, ties in fixed order" do
    second = AgentPlacement.create!(agent: agents(:code_reviewer), backend: "hetzner_cloud", state: "pending")
    third = AgentPlacement.create!(agent: agents(:inactive_agent), backend: "hetzner_cloud", state: "pending")
    fourth = AgentPlacement.create!(agent: agents(:without_tools), backend: "hetzner_cloud", state: "pending")
    hosted = AgentPlacement.create!(agent: agents(:with_save_memory_tool), backend: "hetzner_cloud", state: "pending",
      location: "nbg1", provider_server_id: 1)

    assert_equal "fsn1", plan!(placement: @placement).location
    assert_equal "hel1", plan!(placement: second).location
    # fsn1, nbg1 (hosted) and hel1 each hold one: back to the first in order.
    assert_equal "fsn1", plan!(placement: third).location

    # A refused purchase gives its reservation back.
    CloudProcurementOperation.find_by(agent_placement: third).update!(state: "refused")
    assert_equal "fsn1", CloudProcurementOperation.find_by(agent_placement: @placement).location
    assert_equal "fsn1", plan!(placement: fourth).location
    assert hosted
  end

  test "a planned location survives restart and recovery unchanged" do
    operation = plan!
    @config = @config.with(locations: %w[hel1])
    @client.on_create = ->(_) { raise HetznerCloudClient::CreateOutcomeUnknown.new("timeout", code: "outcome_unknown") }
    service.submit!(operation)

    assert_equal "fsn1", operation.reload.location
    assert_equal "fsn1", @client.creates.first[:location]
  end

  # --- the one create ----------------------------------------------------

  test "mints enrollment and commits intent before the create, with the token only in user_data" do
    operation = plan!
    seen = nil
    @client.on_create = lambda do |request|
      # At the moment of the POST, intent and enrollment are already durable.
      committed = CloudProcurementOperation.connection_pool.with_connection { CloudProcurementOperation.find(operation.id) }
      enrollment = RunnerEnrollment.find_by(procurement_operation_id: operation.id)
      seen = { state: committed.state, enrollment: enrollment, user_data: request[:user_data], request: }
      created_for(operation.reload)
    end

    service.submit!(operation)

    assert_equal "create_in_flight", seen[:state]
    assert seen[:enrollment], "enrollment minted before the create"
    token = YAML.safe_load(seen[:user_data].delete_prefix("#cloud-config\n"))["write_files"]
      .find { |file| file["path"] == "/etc/souls-house-runner/config.json" }["content"].then { JSON.parse(_1)["enrollment_token"] }
    assert_equal seen[:enrollment].token_digest, RunnerEnrollment.digest(token)
    assert_equal IMAGE_ID, seen[:request][:image]
    assert_equal [ 101 ], seen[:request][:ssh_keys]
    assert_equal({ HetznerCloudClient::OPERATION_LABEL => operation.public_id }, seen[:request][:labels])

    operation.reload
    assert_equal "reconciling", operation.state
    assert_equal 4242, operation.provider_server_id
    assert_equal 77, operation.create_action_id
    stored = CloudProcurementOperation.where(id: operation.id).pick(Arel.sql("row_to_json(cloud_procurement_operations)::text"))
    assert_not_includes stored, token
    assert_not_includes RunnerEnrollment.where(id: seen[:enrollment].id).pick(Arel.sql("row_to_json(runner_enrollments)::text")), token
  end

  test "submitting twice, or after another worker claimed it, sends one create" do
    operation = plan!
    stale = CloudProcurementOperation.find(operation.id)
    @client.on_create = ->(_) { created_for(operation.reload) }

    service.submit!(operation)
    service.submit!(operation)
    # A second worker holding the row as it was before the claim re-reads it
    # under the lock and sends nothing.
    service.submit!(stale)

    assert_equal 1, @client.creates.size
    assert_equal 1, RunnerEnrollment.where(procurement_operation_id: operation.id).count
  end

  test "timeouts, 5xx, dropped connections and malformed success are unknown and never retried" do
    operation = plan!
    @client.on_create = ->(_) { raise HetznerCloudClient::CreateOutcomeUnknown.new("timeout", code: "outcome_unknown") }

    service.submit!(operation)
    assert_equal "unknown", operation.reload.state

    3.times { service.reconcile!(operation) }
    service.submit!(operation)
    assert_equal 1, @client.creates.size
    assert_equal "unknown", operation.reload.state
  end

  test "a provider error without a 4xx status is unknown, not a refusal" do
    operation = plan!
    @client.on_create = ->(_) { raise HetznerCloudClient::Error.new("bad gateway", status: 502, code: "http_502") }

    service.submit!(operation)
    assert_equal "unknown", operation.reload.state
    assert_nil operation.runner_enrollment.revoked_at
  end

  test "an unexpected exception during the create is recorded as unknown and re-raised" do
    operation = plan!
    @client.on_create = ->(_) { raise NoMethodError, "boom" }

    assert_raises(NoMethodError) { service.submit!(operation) }
    assert_equal "unknown", operation.reload.state
    assert_equal "unexpected_error", operation.last_error_code
  end

  test "capacity, configuration and validation refusals bought nothing and buy nothing elsewhere" do
    [
      HetznerCloudClient::CapacityUnavailable.new("stock", status: 412, code: "resource_unavailable"),
      HetznerCloudClient::NotConfigured.new("no token", code: "not_configured"),
      HetznerCloudClient::Refused.new("allowlist", code: "refused"),
      HetznerCloudClient::Error.new("bad image", status: 422, code: "invalid_input")
    ].each do |error|
      operation = plan!
      @client.on_create = ->(_) { raise error }
      service.submit!(operation)

      operation.reload
      assert_equal "refused", operation.state, error.code
      assert_equal error.code, operation.last_error_code
      assert operation.runner_enrollment.revoked_at, "enrollment revoked after #{error.code}"
    end
    assert_equal 4, @client.creates.size
    assert_equal [ "fsn1" ], @client.creates.map { _1[:location] }.uniq
  end

  test "a taken provider name needs review rather than a refusal" do
    operation = plan!
    @client.on_create = ->(_) { raise HetznerCloudClient::NameTaken.new("taken", status: 409, code: "uniqueness_error") }

    service.submit!(operation)
    assert_equal "needs_review", operation.reload.state
    assert_equal "provider_name_taken", operation.review_reason
  end

  test "a created server that does not match the request needs review" do
    operation = plan!
    @client.on_create = ->(_) { created_for(operation.reload, server_type: "cx33") }

    service.submit!(operation)
    assert_equal "needs_review", operation.reload.state
    assert_equal 4242, operation.provider_server_id
  end

  # --- crash boundaries ----------------------------------------------------

  test "a crash after intent but before the POST is reconciled, never re-sent or re-minted" do
    operation = plan!
    # Simulate the process dying between commit and request: the row says
    # create_in_flight, the plaintext token is gone.
    enrollment, = RunnerEnrollment.mint!(placement: @placement, operation_id: operation.id, now: @now)
    operation.update!(state: "create_in_flight", create_sent_at: @now)

    service.reconcile!(operation)
    assert_equal "unknown", operation.reload.state
    service.submit!(operation)
    assert_empty @client.creates
    assert_equal [ enrollment.id ], RunnerEnrollment.where(procurement_operation_id: operation.id).pluck(:id)

    later = service(clock: -> { @now + RunnerEnrollment::TOKEN_TTL + 1.minute })
    later.reconcile!(operation)
    assert_equal "needs_review", operation.reload.state
    assert_equal "enrollment_expired_unresolved", operation.review_reason
    assert_empty @client.creates
  end

  test "a lost create reply is recovered by discovery when exactly one verified server exists" do
    operation = plan!
    @client.on_create = lambda do |_|
      created_for(operation.reload)
      raise HetznerCloudClient::CreateOutcomeUnknown.new("dropped", code: "outcome_unknown")
    end
    service.submit!(operation)
    assert_equal "unknown", operation.reload.state

    service.reconcile!(operation)
    assert_equal "reconciling", operation.reload.state
    assert_equal 4242, operation.provider_server_id
    assert_nil operation.create_action_id
  end

  test "delayed discovery: zero matches stays unknown until the server appears" do
    operation = plan!
    @client.on_create = ->(_) { raise HetznerCloudClient::CreateOutcomeUnknown.new("timeout", code: "outcome_unknown") }
    service.submit!(operation)

    service.reconcile!(operation)
    assert_equal "unknown", operation.reload.state

    @client.servers[4242] = server_for(operation)
    service.reconcile!(operation)
    assert_equal "reconciling", operation.reload.state
  end

  test "multiple, mislabelled or wrong-spec discoveries stop for review" do
    { "multiple_servers_found" => ->(op) { [ server_for(op, id: 1), server_for(op, id: 2) ] },
      "discovered_server_mismatch" => ->(op) { [ server_for(op, location: "hel1") ] } }.each do |reason, listing|
      operation = plan!
      operation.update!(state: "unknown")
      @client.on_list = ->(_) { listing.call(operation) }
      service.reconcile!(operation)
      assert_equal "needs_review", operation.reload.state
      assert_equal reason, operation.review_reason
      operation.update!(state: "refused")
    end

    operation = plan!
    operation.update!(state: "unknown")
    wrong = server_for(operation, labels: server_for(operation).labels.merge(HetznerCloudClient::PLACEMENT_LABEL => "999"))
    @client.on_list = ->(_) { [ wrong ] }
    service.reconcile!(operation)
    assert_equal "discovered_server_mismatch", operation.reload.review_reason
  end

  test "a failed or incomplete listing proves nothing and changes nothing" do
    operation = plan!
    operation.update!(state: "unknown")
    @client.on_list = ->(_) { raise HetznerCloudClient::IncompleteListing.new("page 2", code: "incomplete_listing") }

    service.reconcile!(operation)
    assert_equal "unknown", operation.reload.state
    assert_equal "incomplete_listing", operation.last_error_code
  end

  # --- boot ------------------------------------------------------------------

  def reconciling!
    operation = plan!
    @client.on_create = ->(_) { created_for(operation.reload) }
    service.submit!(operation)
    operation.reload
  end

  test "action pending keeps reconciling; success with a running server provisions without making the placement ready" do
    operation = reconciling!
    @client.actions[77] = HetznerCloudClient::Action.new(id: 77, command: "create_server", status: "running", error_code: nil)
    service.reconcile!(operation)
    assert_equal "reconciling", operation.reload.state

    @client.actions[77] = HetznerCloudClient::Action.new(id: 77, command: "create_server", status: "success", error_code: nil)
    @client.servers[4242] = server_for(operation)
    service.reconcile!(operation)

    operation.reload
    assert_equal "provisioned", operation.state
    assert_equal 4242, operation.runner_enrollment.expected_provider_server_id
    @placement.reload
    assert_equal "pending", @placement.state
    assert_equal "fsn1", @placement.location
    assert_equal 4242, @placement.provider_server_id
    assert_not Agents::RuntimeLocation.local?(@placement.agent)
  end

  test "a failed boot action, a vanished server or a swapped server needs review" do
    operation = reconciling!
    @client.actions[77] = HetznerCloudClient::Action.new(id: 77, command: "create_server", status: "error", error_code: "action_failed")
    service.reconcile!(operation)
    assert_equal "create_action_failed", operation.reload.review_reason

    operation.update!(state: "reconciling")
    @client.actions.clear
    @client.servers.clear
    service.reconcile!(operation)
    assert_equal "server_missing", operation.reload.review_reason

    operation.update!(state: "reconciling")
    @client.servers[4242] = server_for(operation, image_id: 1)
    service.reconcile!(operation)
    assert_equal "server_mismatch", operation.reload.review_reason
  end

  test "a server confirmed after the token expired needs review instead of enrollment" do
    operation = reconciling!
    @client.servers[4242] = server_for(operation)
    @client.actions[77] = action(77, "success")
    service(clock: -> { @now + RunnerEnrollment::TOKEN_TTL + 1.second }).reconcile!(operation)

    assert_equal "needs_review", operation.reload.state
    assert_equal "enrollment_unusable", operation.review_reason
    assert_nil operation.runner_enrollment.expected_provider_server_id
  end

  # --- cleanup ---------------------------------------------------------------

  def provisioned!
    operation = reconciling!
    @client.servers[4242] = server_for(operation)
    @client.actions[77] = action(77, "success")
    service.reconcile!(operation)
    operation.reload
  end

  test "delete is accepted while the server is present and finishes only on verified absence" do
    operation = provisioned!
    service.request_delete!(operation, requested_by: @admin)
    assert_equal "deleting", operation.reload.state
    @client.actions[901] = HetznerCloudClient::Action.new(id: 901, command: "delete_server", status: "running", error_code: nil)

    service.reconcile!(operation)
    assert_equal "deleting", operation.reload.state
    assert_equal 1, @client.deletes.size

    @client.servers.delete(4242)
    service.reconcile!(operation)
    operation.reload
    assert_equal "deleted", operation.state
    assert operation.runner_enrollment.revoked_at
    @placement.reload
    assert @placement.persisted?
    assert_nil @placement.provider_server_id
    assert_nil @placement.location
    assert_not Agents::RuntimeLocation.local?(@placement.agent)
  end

  test "a lost delete reply is reconciled and the delete sent again on a later pass" do
    operation = provisioned!
    @client.on_delete = ->(_) { raise HetznerCloudClient::Error.new("dropped", code: "unavailable") }
    service.request_delete!(operation, requested_by: @admin)
    assert_equal "deleting", operation.reload.state
    assert_equal 1, @client.deletes.size

    @client.on_delete = nil
    service.reconcile!(operation)
    assert_equal 2, @client.deletes.size
    assert_equal 902, operation.reload.delete_action_id
  end

  test "delete refused for ownership needs review; non-admins and unverified servers cannot delete" do
    operation = provisioned!
    assert_raises(CloudProcurement::NotAuthorized) { service.request_delete!(operation, requested_by: users(:regular_user)) }

    @client.on_delete = ->(_) { raise HetznerCloudClient::Refused.new("other placement", code: "refused") }
    service.request_delete!(operation, requested_by: @admin)
    assert_equal "needs_review", operation.reload.state
    assert_equal "delete_refused", operation.review_reason

    unknown = plan!(placement: AgentPlacement.create!(agent: agents(:code_reviewer), backend: "hetzner_cloud", state: "pending"))
    unknown.update!(state: "unknown")
    assert_raises(CloudProcurement::NotAllowed) { service.request_delete!(unknown, requested_by: @admin) }
  end

  test "an operator can close an unresolved purchase only when no server is visible" do
    operation = plan!
    operation.update!(state: "unknown")
    RunnerEnrollment.mint!(placement: @placement, operation_id: operation.id, now: @now)

    assert_raises(CloudProcurement::NotAllowed) { service.close_without_server!(operation, requested_by: @admin, reason: "short") }
    @client.servers[4242] = server_for(operation)
    assert_raises(CloudProcurement::NotAllowed) do
      service.close_without_server!(operation, requested_by: @admin, reason: "checked the Hetzner console")
    end

    @client.servers.clear
    service.close_without_server!(operation, requested_by: @admin, reason: "checked the Hetzner console")
    assert_equal "refused", operation.reload.state
    assert operation.runner_enrollment.revoked_at
    assert plan!.persisted?
  end

  # --- review repairs (Mira, 143abd62) ----------------------------------------

  test "ambiguous or unrecognised provider errors keep the reservation" do
    [
      HetznerCloudClient::Error.new("timeout", status: 408, code: "http_408"),
      HetznerCloudClient::Error.new("odd", status: 400, code: "something_new"),
      HetznerCloudClient::Error.new("conflict", status: 409, code: "conflict"),
      HetznerCloudClient::Error.new("contradiction", status: 503, code: "invalid_input")
    ].each do |error|
      operation = plan!
      @client.on_create = ->(_) { raise error }
      service.submit!(operation)

      assert_equal "unknown", operation.reload.state, "#{error.status} #{error.code}"
      assert_nil operation.runner_enrollment.revoked_at
      assert_raises(CloudProcurement::NotAllowed) { plan! }
      operation.update_columns(state: "refused")
    end
  end

  test "a worker that stalls past the submit deadline after its claim never sends the create" do
    operation = plan!
    clock = @now
    @client.on_create = ->(_) { flunk "no create after the deadline" }
    stalling = Object.new
    renderer = RunnerUserData
    stalling.define_singleton_method(:render) do |**kwargs|
      rendered = renderer.render(**kwargs)
      clock += CloudProcurement::SUBMIT_DEADLINE + 1.second
      rendered
    end
    CloudProcurement.new(client: @client, config: @config, renderer: stalling, clock: -> { clock }).submit!(operation)

    assert_equal "needs_review", operation.reload.state
    assert_equal "submit_deadline_passed", operation.review_reason
    assert_empty @client.creates
  end

  test "an operator cannot close a purchase while its submit could still be live" do
    operation = plan!
    @client.on_create = ->(_) { raise HetznerCloudClient::CreateOutcomeUnknown.new("timeout", code: "outcome_unknown") }
    service.submit!(operation)
    assert_equal "unknown", operation.reload.state

    inside = service(clock: -> { @now + CloudProcurement::CLOSE_FENCE - 1.second })
    error = assert_raises(CloudProcurement::NotAllowed) do
      inside.close_without_server!(operation, requested_by: @admin, reason: "checked the Hetzner console")
    end
    assert_match(/may still be in progress/, error.message)

    after = service(clock: -> { @now + CloudProcurement::CLOSE_FENCE + 1.second })
    after.close_without_server!(operation, requested_by: @admin, reason: "checked the Hetzner console")
    assert_equal "refused", operation.reload.state
  end

  test "a server that arrives for a closed purchase is recorded, not dropped" do
    operation = plan!
    operation.update!(state: "refused", create_sent_at: @now)
    created = created_for(operation)
    service.send(:record_created!, operation, created)

    operation.reload
    assert_equal "refused", operation.state
    assert_equal 4242, operation.provider_server_id
    assert_equal "server_arrived_after_close:refused", operation.review_reason
  end

  test "a recorded boot action must be found, match and succeed explicitly" do
    operation = reconciling!
    @client.servers[4242] = server_for(operation)

    service.reconcile!(operation)
    assert_equal "create_action_missing", operation.reload.review_reason

    operation.update_columns(state: "reconciling", review_reason: nil)
    @client.actions[77] = action(77, "paused")
    service.reconcile!(operation)
    assert_equal "create_action_unrecognised", operation.reload.review_reason

    operation.update_columns(state: "reconciling", review_reason: nil)
    @client.actions[77] = action(77, "success")
    @client.servers[4242] = server_for(operation, status: "starting")
    service.reconcile!(operation)
    assert_equal "reconciling", operation.reload.state
  end

  test "a discovered server's boot action is recovered from its history before boot is accepted" do
    operation = plan!
    operation.update!(state: "unknown")
    RunnerEnrollment.mint!(placement: @placement, operation_id: operation.id, now: @now)
    @client.servers[4242] = server_for(operation)
    service.reconcile!(operation)
    assert_nil operation.reload.create_action_id

    # Running, but no boot action on record: not provisioned.
    service.reconcile!(operation)
    assert_equal "create_action_unverifiable", operation.reload.review_reason

    operation.update_columns(state: "reconciling", review_reason: nil)
    @client.create_actions = { 4242 => [ action(88, "success") ] }
    service.reconcile!(operation)
    assert_equal 88, operation.reload.create_action_id
    assert_equal "reconciling", operation.state

    @client.actions[88] = action(88, "success")
    service.reconcile!(operation)
    assert_equal "provisioned", operation.reload.state
  end

  test "the reconcile job reschedules only while an operation is settling" do
    operation = plan!
    operation.update!(state: "unknown")
    RunnerEnrollment.mint!(placement: @placement, operation_id: operation.id, now: @now)
    CloudProcurement.stub(:from_credentials, service) do
      assert_enqueued_with(job: CloudProcurementReconcileJob, args: [ operation.id ]) do
        CloudProcurementReconcileJob.perform_now(operation.id)
      end
      operation.update!(state: "provisioned")
      assert_no_enqueued_jobs { CloudProcurementReconcileJob.perform_now(operation.id) }
    end
  end

end
