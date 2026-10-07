require "test_helper"

module Agents
  class RuntimeLocationTest < ActiveSupport::TestCase

    setup do
      @agent = agents(:research_assistant)
    end

    test "legacy residents and explicit ready local placements keep their endpoint" do
      @agent.update!(endpoint_url: "http://127.0.0.1:4567")
      Config.stub(:publish_ports?, true) do
        assert_equal @agent.endpoint_url, Endpoint.url_for(@agent)
        AgentPlacement.create!(agent: @agent, backend: "local", state: "ready")
        assert_equal @agent.endpoint_url, Endpoint.url_for(@agent)
      end
      Config.stub(:publish_ports?, false) do
        assert_equal "http://#{@agent.container_name}:4000", Endpoint.url_for(@agent)
      end
    end

    test "remote placements never fall back to a stale local or development endpoint" do
      @agent.update!(endpoint_url: "http://127.0.0.1:4567")
      AgentPlacement.create!(agent: @agent, backend: "hetzner_cloud", state: "ready",
        provider_server_id: 123, runtime_endpoint: "https://resident.example.test")
      [ true, false ].each do |published|
        Config.stub(:publish_ports?, published) do
          assert_raises(RuntimeLocation::Unavailable) { Endpoint.url_for(@agent) }
        end
      end
    end

    test "non-ready local placements are not authority to run" do
      %w[pending failed retired].each do |state|
        placement = AgentPlacement.create!(agent: @agent, backend: "local", state: state)
        assert_raises(RuntimeLocation::Unavailable) { RuntimeLocation.require_local!(@agent) }
        placement.destroy!
      end
    end

    test "a previously cached absence does not authorize local access" do
      assert_nil @agent.placement
      AgentPlacement.create!(agent: @agent, backend: "hetzner_cloud", state: "pending")
      assert_raises(RuntimeLocation::Unavailable) { RuntimeLocation.require_local!(@agent) }
    end

    test "remote resources are refused even in the legacy production namespace" do
      AgentPlacement.create!(agent: @agent, backend: "hetzner_cloud", state: "pending")
      instance = LocalInstance::Configuration.new(root: Rails.root, env: {}, environment: "production")
      DockerLocalGuard.stub(:check!, -> { flunk "Docker guard must not be reached" }) do
        assert_raises(Resources::OwnershipError) do
          Resources.new(@agent, instance: instance).verify_existing!
        end
      end
    end

    test "remote lifecycle refuses before network setup and does not yield a warm runtime" do
      AgentPlacement.create!(agent: @agent, backend: "hetzner_cloud", state: "pending")
      sandbox = Sandbox.new(@agent)
      Network.stub(:ensure!, -> { flunk "local network must not be created" }) do
        assert_raises(RuntimeLocation::Unavailable) { sandbox.spawn! }
        assert_raises(RuntimeLocation::Unavailable) { sandbox.recreate! }
      end
      Config.stub(:cold_start?, false) do
        assert_raises(RuntimeLocation::Unavailable) do
          sandbox.with_runtime { flunk "remote runtime must not be yielded" }
        end
      end
    end

    test "remote backup configuration refuses before obtaining storage credentials" do
      AgentPlacement.create!(agent: @agent, backend: "hetzner_cloud", state: "pending")
      Backup::AgentRestic.stub(:aws_credentials, -> { flunk "must not obtain backup credentials" }) do
        assert_raises(RuntimeLocation::Unavailable) { Backup::AgentRestic.docker_environment(@agent) }
      end
    end

    test "remote stop removal and volume operations refuse before subprocess execution" do
      AgentPlacement.create!(agent: @agent, backend: "hetzner_cloud", state: "pending")
      sandbox = Sandbox.new(@agent)
      volume = Volume.new(@agent)
      Open3.stub(:capture3, ->(*) { flunk "must not run a subprocess" }) do
        sandbox.stub(:system, ->(*) { flunk "must not invoke Docker" }) do
          assert_raises(Resources::OwnershipError) { sandbox.stop! }
          assert_raises(Resources::OwnershipError) { sandbox.remove!(delete_volume: true) }
        end
        volume.stub(:system, ->(*) { flunk "must not invoke Docker" }) do
          assert_raises(Resources::OwnershipError) { volume.ensure! }
          assert_raises(Resources::OwnershipError) { volume.destroy! }
        end
      end
    end

  end
end
