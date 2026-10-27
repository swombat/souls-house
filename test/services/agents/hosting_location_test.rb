require "test_helper"

class Agents::HostingLocationTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:research_assistant)
    @agent.update_columns(runtime: "external")
  end

  test "a resident without a placement runs on the main server" do
    assert_equal({ kind: "house" }, Agents::HostingLocation.call(@agent))
  end

  test "a local placement is the main server too" do
    AgentPlacement.create!(agent: @agent, backend: "local", state: "ready")
    assert_equal({ kind: "house" }, Agents::HostingLocation.call(@agent))
  end

  test "a VM resident gets the server type, its size and the city" do
    placement = AgentPlacement.create!(agent: @agent, backend: "hetzner_cloud", state: "ready",
      location: "fsn1", provider_server_id: 4242)
    purchase(placement, "cx33", state: "provisioned")

    assert_equal({ kind: "vm", ready: true, server_type: "CX33", vcpus: 4, ram_gb: 8, disk_gb: 80,
      location: "Falkenstein, Germany" }, Agents::HostingLocation.call(@agent))
  end

  test "a deleted earlier server is not the one it is on" do
    placement = AgentPlacement.create!(agent: @agent, backend: "hetzner_cloud", state: "ready",
      location: "hel1", provider_server_id: 4243)
    purchase(placement, "cx23", state: "deleted")
    purchase(placement, "cx43", state: "provisioned")

    result = Agents::HostingLocation.call(@agent)
    assert_equal "CX43", result[:server_type]
    assert_equal 16, result[:ram_gb]
    assert_equal "Helsinki, Finland", result[:location]
  end

  test "a VM still being bought says it is not ready, from the purchase's location" do
    placement = AgentPlacement.create!(agent: @agent, backend: "hetzner_cloud", state: "pending")
    purchase(placement, "cx23", state: "create_in_flight", location: "nbg1")

    result = Agents::HostingLocation.call(@agent)
    assert_equal false, result[:ready]
    assert_equal "CX23", result[:server_type]
    assert_equal "Nuremberg, Germany", result[:location]
  end

  test "a resident with no hosted runtime has nothing to say" do
    @agent.update_columns(runtime: "deprecated")
    assert_nil Agents::HostingLocation.call(@agent)
  end

  private

  def purchase(placement, server_type, state:, location: placement.location)
    CloudProcurementOperation.create!(agent_placement: placement, requested_by: users(:site_admin_user),
      public_id: SecureRandom.hex(4), approval_reference: "test", location: location, server_type: server_type,
      image_id: 1, ssh_key_ids: [ 1 ], provider_name: "resident-#{SecureRandom.hex(3)}", state: state)
  end

end
