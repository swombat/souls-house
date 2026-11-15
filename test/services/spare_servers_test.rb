require "test_helper"

class SpareServersTest < ActiveSupport::TestCase

  include ActiveJob::TestHelper

  IMAGE_ID = 161_547_269

  # Stands in for HetznerCloudClient: records creates and answers as told.
  class FakeClient

    attr_reader :creates
    attr_accessor :on_create

    def initialize
      @creates = []
      @next_id = 5000
    end

    def create_server_with_action(**kwargs)
      @creates << kwargs
      return on_create.call(kwargs) if on_create

      labels = kwargs[:labels].merge(HetznerCloudClient::MANAGED_LABEL => "true",
        HetznerCloudClient::PLACEMENT_LABEL => kwargs[:placement_id])
      server = HetznerCloudClient::Server.new(id: (@next_id += 1), name: kwargs[:name], status: "initializing",
        server_type: kwargs[:server_type], location: kwargs[:location], image_id: kwargs[:image], ipv4: "203.0.113.9",
        ipv6: "2001:db8::/64", labels:)
      HetznerCloudClient::Created.new(server:, action_id: 77, action_status: "running")
    end

  end

  setup do
    @client = FakeClient.new
    config = CloudProcurement::Config.new(image_id: IMAGE_ID, ssh_key_ids: [ 101 ], locations: %w[fsn1 nbg1 hel1],
      rails_url: "https://souls.example")
    @procurement = CloudProcurement.new(client: @client, config:)
    @setting = Setting.instance
    @setting.update!(spare_server_limit: 2, spare_cx33_target: 1)
  end

  def spares
    SpareServers.new(setting: @setting, procurement: @procurement)
  end

  def selling(type, *locations)
    { type => %w[fsn1 nbg1 hel1].index_with { |location| locations.include?(location) } }
  end

  # A resident on a CX23 whose plan in force names the given tier.
  def resident_on_cx23(agent, tier:)
    placement = AgentPlacement.create!(agent:, backend: "hetzner_cloud", state: "ready",
      provider_server_id: 9000 + agent.id, location: "fsn1")
    CloudProcurementOperation.create!(agent_placement: placement, requested_by: users(:site_admin_user),
      public_id: "cpo-res#{agent.id}", approval_reference: "test", server_type: "cx23", location: "fsn1",
      image_id: IMAGE_ID, ssh_key_ids: [ 101 ], provider_name: "souls-house-res#{agent.id}", state: "provisioned",
      provider_server_id: 9000 + agent.id)
    ResidentEntitlement.for_agent!(agent).update!(tier:, state: "complimentary", source: "complimentary")
    placement
  end

  test "nothing is ordered while the limit is 0, whatever is on sale" do
    @setting.update!(spare_server_limit: 0)

    assert_empty spares.replenish!(selling("cx33", "nbg1"))
    assert_empty @client.creates
    assert_equal 0, CloudProcurementOperation.count
  end

  test "a window orders the spare target, once: the next check sees it held and orders nothing" do
    ordered = spares.replenish!(selling("cx33", "nbg1"))

    assert_equal 1, ordered.size
    operation = ordered.first.reload
    assert_equal [ "spare", "cx33", "nbg1", "reconciling" ],
      [ operation.purpose, operation.server_type, operation.location, operation.state ]
    assert_nil operation.agent_placement_id
    assert_nil operation.runner_enrollment
    create = @client.creates.sole
    assert_equal "spare", create[:placement_id]
    assert_nil create[:user_data]
    assert_equal "spare_server_ordered", AuditLog.last.action

    assert_empty spares.replenish!(selling("cx33", "nbg1"))
    assert_equal 1, @client.creates.size
  end

  test "a resident waiting for a bigger server adds one to what is wanted, up to the cap" do
    resident_on_cx23(agents(:research_assistant), tier: "life")
    resident_on_cx23(agents(:code_reviewer), tier: "life")
    assert_equal 2, spares.waiting("cx33")
    assert_equal 0, spares.waiting("cx43")

    # Wanted: two waiting plus one spare. The cap is 2.
    ordered = spares.replenish!(selling("cx33", "nbg1", "hel1"))

    assert_equal 2, ordered.size
    assert_equal %w[hel1 nbg1], ordered.map(&:location).sort
    assert_empty spares.replenish!(selling("cx33", "nbg1", "hel1"))
  end

  test "a resident already on the server its plan names is not waiting" do
    resident_on_cx23(agents(:research_assistant), tier: "conversation")

    assert_equal 0, spares.waiting("cx33")
  end

  test "an order whose outcome is unknown still counts, so no second order is sent" do
    @client.on_create = ->(_) { raise HetznerCloudClient::CreateOutcomeUnknown.new("lost", code: "outcome_unknown") }
    spares.replenish!(selling("cx33", "nbg1"))
    assert_equal "unknown", CloudProcurementOperation.spares.sole.state

    @client.on_create = nil
    assert_empty spares.replenish!(selling("cx33", "nbg1"))
    assert_equal 1, @client.creates.size
  end

  test "a refused order frees its place, and that location is left alone for a while" do
    @client.on_create = lambda do |_|
      raise HetznerCloudClient::CapacityUnavailable.new("none", status: 412, code: "resource_unavailable")
    end
    spares.replenish!(selling("cx33", "nbg1"))
    assert_equal "refused", CloudProcurementOperation.spares.sole.state

    @client.on_create = nil
    assert_empty spares.replenish!(selling("cx33", "nbg1"))
    assert_equal 1, @client.creates.size

    # Another location is still tried, and nbg1 again once the pause is over.
    assert_equal [ "hel1" ], spares.replenish!(selling("cx33", "nbg1", "hel1")).map(&:location)
    CloudProcurementOperation.spares.where(state: "refused").update_all(updated_at: 21.minutes.ago)
    @setting.update!(spare_server_limit: 3, spare_cx33_target: 2)
    assert_equal [ "nbg1" ], spares.replenish!(selling("cx33", "nbg1")).map(&:location)
  end

  # Mira, #977: a worker that stops after the reservation commits must not
  # leave a planned spare holding the cap forever.
  test "a spare left planned by a stopped worker is sent by the next check, once" do
    stranded = CloudProcurementOperation.transaction do
      @procurement.plan_spare!(server_type: "cx33", location: "nbg1", approval_reference: "setting:spare_servers/cx33")
    end

    assert_empty spares.replenish!(selling("cx33"))
    assert_equal "reconciling", stranded.reload.state
    assert_equal 1, @client.creates.size

    spares.replenish!(selling("cx33", "nbg1"))
    assert_equal 1, @client.creates.size
  end

  test "a spare left settling with no reconcile job gets one again and is never sent twice" do
    @client.on_create = ->(_) { raise HetznerCloudClient::CreateOutcomeUnknown.new("lost", code: "outcome_unknown") }
    operation = spares.replenish!(selling("cx33", "nbg1")).sole
    clear_enqueued_jobs

    spares.replenish!(selling("cx33", "nbg1"))
    assert_no_enqueued_jobs only: CloudProcurementReconcileJob

    operation.update_columns(last_reconciled_at: 4.minutes.ago, updated_at: 4.minutes.ago)
    assert_enqueued_with(job: CloudProcurementReconcileJob, args: [ operation.id ]) do
      spares.replenish!(selling("cx33", "nbg1"))
    end
    assert_equal 1, @client.creates.size
  end

  test "recovery runs even after the limit is set back to 0" do
    stranded = @procurement.plan_spare!(server_type: "cx33", location: "nbg1", approval_reference: "t")
    @setting.update!(spare_server_limit: 0)

    assert_empty spares.replenish!(selling("cx33", "nbg1"))
    assert_equal "reconciling", stranded.reload.state
  end

  # Mira, #977: a location Hetzner sells but this installation does not allow
  # must not roll back the valid order beside it.
  test "only the installation's allowed locations are used, and the rest of the batch still orders" do
    narrow = CloudProcurement.new(client: @client, config: CloudProcurement::Config.new(image_id: IMAGE_ID,
      ssh_key_ids: [ 101 ], locations: %w[hel1], rails_url: "https://souls.example"))
    @setting.update!(spare_server_limit: 2, spare_cx33_target: 2)

    ordered = SpareServers.new(setting: @setting, procurement: narrow).replenish!(selling("cx33", "fsn1", "hel1"))

    assert_equal %w[hel1 hel1], ordered.map(&:location)
    assert_empty SpareServers.new(setting: @setting, procurement: narrow).replenish!(selling("cx33", "fsn1"))
  end

  test "choosing a location for a resident's server counts each spare, not all spares as one" do
    2.times { @procurement.plan_spare!(server_type: "cx33", location: "fsn1", approval_reference: "t") }
    @procurement.plan_spare!(server_type: "cx33", location: "nbg1", approval_reference: "t")
    placement = AgentPlacement.create!(agent: agents(:research_assistant), backend: "hetzner_cloud", state: "pending")

    operation = @procurement.plan!(placement:, requested_by: users(:site_admin_user), approval_reference: "t",
      server_type: "cx23")

    assert_equal "hel1", operation.location
  end

  test "a type that is not on sale, or sold only outside the approved locations, is not ordered" do
    assert_empty spares.replenish!(selling("cx33"))
    assert_empty spares.replenish!("cx33" => { "ash" => true })
    assert_empty spares.replenish!({})
    assert_empty @client.creates
  end

  test "a spare boots to provisioned with no runner, and an admin can release it" do
    operation = spares.replenish!(selling("cx33", "nbg1")).sole
    server = @client.creates.sole.then do |create|
      HetznerCloudClient::Server.new(id: operation.reload.provider_server_id, name: create[:name], status: "running",
        server_type: "cx33", location: "nbg1", image_id: IMAGE_ID, ipv4: "203.0.113.9", ipv6: nil,
        labels: create[:labels].merge(HetznerCloudClient::MANAGED_LABEL => "true",
          HetznerCloudClient::PLACEMENT_LABEL => "spare"))
    end
    deletes = []
    @client.define_singleton_method(:find_server) { |_id| deletes.empty? ? server : nil }
    @client.define_singleton_method(:find_action) do |id|
      HetznerCloudClient::Action.new(id:, command: "create_server", status: "success", error_code: nil)
    end
    @client.define_singleton_method(:delete_server) do |id, placement_id:|
      deletes << [ id, placement_id ]
      HetznerCloudClient::DeleteAccepted.new(server_id: id, action_id: 901, action_status: "running")
    end

    assert_equal "provisioned", @procurement.reconcile!(operation).state
    assert_equal 1, spares.status[:counted]

    released = @procurement.request_delete!(operation, requested_by: users(:site_admin_user))
    assert_equal [ [ server.id, "spare" ] ], deletes
    assert_equal "deleted", released.state
    assert_equal 0, spares.status[:counted]
  end

  test "the availability check orders from the answer it just recorded" do
    availability = selling("cx33", "nbg1")
    client = Object.new
    client.define_singleton_method(:server_type_availability) { availability }
    seen = nil
    HetznerCloudClient.stub(:from_credentials, client) do
      SpareServers.stub(:replenish!, ->(given) { seen = given }) { HetznerAvailabilityCheckJob.perform_now }
    end

    assert_equal availability, seen
  end

  test "a failure while ordering never loses the availability sample" do
    client = Object.new
    client.define_singleton_method(:server_type_availability) { { "cx33" => { "nbg1" => true } } }
    HetznerCloudClient.stub(:from_credentials, client) do
      SpareServers.stub(:replenish!, ->(_) { raise "boom" }) { HetznerAvailabilityCheckJob.perform_now }
    end

    assert HetznerAvailabilitySample.exists?(server_type: "cx33", location: "nbg1", available: true)
  end

  test "a purchase is a spare or has a placement, never both or neither" do
    assert_raises(ActiveRecord::RecordInvalid) do
      CloudProcurementOperation.create!(purpose: "placement", public_id: "cpo-x", approval_reference: "t",
        server_type: "cx23", location: "fsn1", image_id: IMAGE_ID, ssh_key_ids: [ 101 ], provider_name: "n")
    end
    spare = @procurement.plan_spare!(server_type: "cx33", location: "nbg1", approval_reference: "t")
    assert_raises(ActiveRecord::StatementInvalid) { spare.update_columns(purpose: "placement") }
  end

end
