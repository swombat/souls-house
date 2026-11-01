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

    assert_equal({ kind: "vm", status: "ready", server_type: "CX33", vcpus: 4, ram_gb: 8, disk_gb: 80,
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

  test "a resident being born onto a VM says its server is being set up, from the purchase's location" do
    @agent.update_columns(runtime: "provisioning")
    placement = AgentPlacement.create!(agent: @agent, backend: "hetzner_cloud", state: "pending")
    purchase(placement, "cx23", state: "create_in_flight", location: "nbg1")

    result = Agents::HostingLocation.call(@agent)
    assert_equal "pending", result[:status]
    assert_equal "CX23", result[:server_type]
    assert_equal "Nuremberg, Germany", result[:location]
  end

  test "a resident being born on the main server says so" do
    @agent.update_columns(runtime: "provisioning")
    assert_equal({ kind: "house" }, Agents::HostingLocation.call(@agent))
  end

  test "an offline resident whose VM placement was retired is on no server, not the main one" do
    @agent.update_columns(runtime: "offline")
    placement = AgentPlacement.create!(agent: @agent, backend: "hetzner_cloud", state: "retired", location: "fsn1")
    purchase(placement, "cx23", state: "deleted")
    assert_equal({ kind: "none" }, Agents::HostingLocation.call(@agent))
  end

  test "a staged move reports staged, with no server yet" do
    AgentPlacement.create!(agent: @agent, backend: "hetzner_cloud", state: "staged", kind: "migration")
    result = Agents::HostingLocation.call(@agent)
    assert_equal "staged", result[:status]
    assert_nil result[:server_type]
  end

  test "a failed VM placement whose server may still exist says setup failed, not that there is no server" do
    placement = AgentPlacement.create!(agent: @agent, backend: "hetzner_cloud", state: "failed",
      location: "fsn1", provider_server_id: 4244)
    purchase(placement, "cx23", state: "provisioned")
    assert_equal({ kind: "failed" }, Agents::HostingLocation.call(@agent))
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
