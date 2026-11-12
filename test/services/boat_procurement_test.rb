require "test_helper"

class BoatProcurementTest < ActiveSupport::TestCase

  # Stands in for BoatClient. Records every call; nothing touches the network.
  class FakeClient

    attr_reader :creates, :deletes
    attr_accessor :on_create, :sandboxes, :on_list, :on_delete

    def initialize
      @creates = []
      @deletes = []
      @sandboxes = {}
    end

    def create_sandbox(**kwargs)
      @creates << kwargs
      on_create.call(kwargs)
    end

    def find_sandbox(id)
      sandboxes[id]
    end

    def find_by_operation(public_id)
      return on_list.call(public_id) if on_list

      sandboxes.values.select { |sandbox| sandbox.operation_id == public_id }
    end

    def delete_sandbox(id, placement_id:)
      @deletes << [ id, placement_id ]
      on_delete ? on_delete.call(id) : BoatClient::DeleteAccepted.new(sandbox_id: id, operation_id: "op_1")
    end

  end

  # Captures the token instead of packaging a runner bundle.
  class FakeRenderer

    attr_reader :tokens

    def initialize = @tokens = []

    def render(enrollment:, token:, rails_url:, commands_enabled:)
      @tokens << token
      "#!/bin/bash\n# #{enrollment.public_id} #{rails_url} #{commands_enabled}\n"
    end

  end

  SANDBOX_ID = "bx_23456789".freeze

  setup do
    @admin = users(:site_admin_user)
    @client = FakeClient.new
    @renderer = FakeRenderer.new
    @now = Time.zone.parse("2026-11-12 19:00:00")
    @config = BoatProcurement::Config.new(rails_url: "https://souls.example")
    @placement = AgentPlacement.create!(agent: agents(:research_assistant), backend: "boat", state: "pending")
  end

  def service(clock: -> { @now })
    BoatProcurement.new(client: @client, config: @config, renderer: @renderer, clock:)
  end

  def plan!(placement: @placement, by: @admin)
    service.plan!(placement:, requested_by: by, approval_reference: "house room ePokyY")
  end

  def sandbox_for(operation, id: SANDBOX_ID, state: "ready", setup_status: "pending", **overrides)
    labels = {
      BoatClient::MANAGED_LABEL => "true",
      BoatClient::PLACEMENT_LABEL => operation.agent_placement_id.to_s,
      BoatClient::OPERATION_LABEL => operation.public_id
    }
    BoatClient::Sandbox.new(**{ id:, name: operation.provider_name, state:, size: "small", error: nil,
      stopped_at: nil, data_expired_at: nil, labels:, setup_status:, setup_error: nil, stop: nil,
      ttl_seconds: nil }.merge(overrides))
  end

  # Test-only: history is never deleted in the app.
  def reset_purchases!
    RunnerEnrollment.where(agent_placement: @placement).delete_all
    BoatProcurementOperation.where(agent_placement: @placement).delete_all
  end

  def submitted(on_create: ->(_) { raise BoatClient::CreateOutcomeUnknown.new("timeout", code: "outcome_unknown") })
    operation = plan!
    @client.on_create = on_create
    service.submit!(operation)
  end

  test "only an installation admin plans, only for an unprovisioned Boat placement, one at a time" do
    assert_raises(BoatProcurement::NotAuthorized) { plan!(by: users(:regular_user)) }

    hetzner = AgentPlacement.create!(agent: agents(:code_reviewer), backend: "hetzner_cloud", state: "pending")
    assert_raises(BoatProcurement::NotAllowed) { plan!(placement: hetzner) }

    operation = plan!
    assert_equal "planned", operation.state
    assert_match(/\Abpo-[0-9a-f]{16}\z/, operation.public_id)
    assert_equal "small", operation.sandbox_size
    assert_raises(BoatProcurement::NotAllowed) { plan! }
    assert_empty @client.creates
  end

  test "submit sends exactly one create, keyed by the operation, carrying a Boat enrollment's token" do
    operation = plan!
    @client.on_create = ->(_) { sandbox_for(operation) }

    service.submit!(operation)
    service.submit!(operation)

    assert_equal 1, @client.creates.size
    create = @client.creates.first
    assert_equal operation.public_id, create[:idempotency_key]
    assert_equal operation.public_id, create[:operation_id]
    assert_equal @placement.id.to_s, create[:placement_id]
    assert_not create.key?(:ttl_seconds)
    assert_equal "reconciling", operation.reload.state
    assert_equal SANDBOX_ID, operation.provider_sandbox_id

    enrollment = operation.runner_enrollment
    assert_equal "boat", enrollment.procurement_kind
    assert_equal RunnerEnrollment.digest(@renderer.tokens.sole), enrollment.token_digest
  end

  test "a stalled claim past the submit deadline never sends its create" do
    operation = plan!
    # The claim reads the clock once; the check before the POST reads it late.
    clock_values = [ @now, @now + BoatProcurement::SUBMIT_DEADLINE + 1.second ]
    late = BoatProcurement.new(client: @client, config: @config, renderer: @renderer,
      clock: -> { clock_values.shift || (@now + 1.hour) })

    late.submit!(operation)

    assert_empty @client.creates
    assert_equal "needs_review", operation.reload.state
    assert_equal "submit_deadline_passed", operation.review_reason
  end

  test "a documented refusal or capacity answer frees the placement and revokes the token" do
    [ BoatClient::CapacityUnavailable.new("no machine", status: 503, code: "no_ready_machine"),
      BoatClient::Error.new("bad script", status: 400, code: "invalid_setup_script") ].each do |error|
      operation = submitted(on_create: ->(_) { raise error })

      assert_equal "refused", operation.state
      assert_equal error.code, operation.last_error_code
      assert operation.runner_enrollment.revoked_at
    end
  end

  test "an ambiguous create stays unresolved, including idempotency answers and unknown 4xx codes" do
    [ BoatClient::CreateOutcomeUnknown.new("timeout", code: "outcome_unknown"),
      BoatClient::Error.new("in progress", status: 409, code: "idempotency_in_progress"),
      BoatClient::Error.new("reused", status: 422, code: "idempotency_key_reused"),
      BoatClient::Error.new("new", status: 400, code: "something_new") ].each do |error|
      reset_purchases!
      operation = submitted(on_create: ->(_) { raise error })

      assert_equal "unknown", operation.state, error.code
      assert_nil operation.runner_enrollment.revoked_at
      assert_raises(BoatProcurement::NotAllowed) { plan! }
    end
  end

  test "reconciling an unknown create tells zero, one and many matches apart" do
    operation = submitted

    service.reconcile!(operation)
    assert_equal "unknown", operation.reload.state

    other = sandbox_for(operation, id: "bx_33333333")
    @client.on_list = ->(_) { [ sandbox_for(operation), other ] }
    service.reconcile!(operation)
    assert_equal "needs_review", operation.reload.state
    assert_equal "multiple_sandboxes_found", operation.review_reason
  end

  test "one matching sandbox is recorded; one that does not match goes to an operator" do
    operation = submitted
    @client.sandboxes[SANDBOX_ID] = sandbox_for(operation)
    service.reconcile!(operation)
    assert_equal "reconciling", operation.reload.state

    reset_purchases!
    @client.sandboxes.clear
    operation = submitted
    @client.on_list = ->(_) { [ sandbox_for(operation, size: "large") ] }
    service.reconcile!(operation)
    assert_equal "needs_review", operation.reload.state
    assert_equal "discovered_sandbox_mismatch", operation.review_reason
  end

  test "an unknown create whose token has expired goes to an operator, never to refused" do
    operation = submitted
    later = BoatProcurement.new(client: @client, config: @config, renderer: @renderer,
      clock: -> { @now + RunnerEnrollment::TOKEN_TTL + 1.minute })

    later.reconcile!(operation)

    assert_equal "needs_review", operation.reload.state
    assert_equal "enrollment_expired_unresolved", operation.review_reason
  end

  test "provisioned needs the setup script done on an awake sandbox, and still is not ready" do
    operation = plan!
    @client.on_create = ->(_) { sandbox_for(operation, state: "provisioning") }
    service.submit!(operation)

    @client.sandboxes[SANDBOX_ID] = sandbox_for(operation, setup_status: "running")
    service.reconcile!(operation)
    assert_equal "reconciling", operation.reload.state

    @client.sandboxes[SANDBOX_ID] = sandbox_for(operation, state: "archived", setup_status: "done")
    service.reconcile!(operation)
    assert_equal "reconciling", operation.reload.state

    @client.sandboxes[SANDBOX_ID] = sandbox_for(operation, setup_status: "done")
    service.reconcile!(operation)
    assert_equal "provisioned", operation.reload.state
    assert_equal SANDBOX_ID, @placement.reload.provider_sandbox_id
    assert_equal "pending", @placement.state
    assert_equal SANDBOX_ID, operation.runner_enrollment.expected_provider_sandbox_id
    assert_nil operation.runner_enrollment.expected_provider_server_id
  end

  test "a failed or unrecognised setup goes to an operator" do
    { "failed" => "setup_failed", nil => "setup_status_unrecognised" }.each do |status, reason|
      reset_purchases!
      operation = plan!
      @client.on_create = ->(_) { sandbox_for(operation) }
      service.submit!(operation)
      @client.sandboxes[SANDBOX_ID] = sandbox_for(operation, setup_status: status)

      service.reconcile!(operation)

      assert_equal "needs_review", operation.reload.state
      assert_equal reason, operation.review_reason
    end
  end

  test "a failed read proves nothing" do
    operation = submitted
    @client.on_list = ->(_) { raise BoatClient::Error.new("down", status: 500, code: "http_500") }

    service.reconcile!(operation)

    assert_equal "unknown", operation.reload.state
    assert_equal "http_500", operation.last_error_code
  end

  test "delete is only for a verified sandbox and finishes on Boat's 404" do
    operation = plan!
    @client.on_create = ->(_) { sandbox_for(operation, setup_status: "done") }
    service.submit!(operation)
    @client.sandboxes[SANDBOX_ID] = sandbox_for(operation, setup_status: "done")
    service.reconcile!(operation)
    assert_equal "provisioned", operation.reload.state

    assert_raises(BoatProcurement::NotAuthorized) { service.request_delete!(operation, requested_by: users(:regular_user)) }

    service.request_delete!(operation, requested_by: @admin)
    assert_equal [ [ SANDBOX_ID, @placement.id.to_s ] ], @client.deletes
    assert_equal "deleting", operation.reload.state

    @client.sandboxes.delete(SANDBOX_ID)
    service.reconcile!(operation)
    assert_equal "deleted", operation.reload.state
    assert_nil @placement.reload.provider_sandbox_id
    assert operation.runner_enrollment.revoked_at
  end

  test "an unprovisioned operation cannot be deleted" do
    operation = submitted
    assert_raises(BoatProcurement::NotAllowed) { service.request_delete!(operation, requested_by: @admin) }
    assert_empty @client.deletes
  end

end
