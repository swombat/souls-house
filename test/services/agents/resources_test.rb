require "test_helper"

module Agents
  class ResourcesTest < ActiveSupport::TestCase

    def configuration(number, environment = "development")
      LocalInstance::Configuration.new(root: Rails.root, env: { "SOULSHOUSE_INSTANCE" => number.to_s }, environment: environment)
    end

    def resident
      Struct.new(:uuid, :container_name).new("test-resident-uuid", nil)
    end

    test "all five volume types and containers differ across instances and test" do
      resources = [ configuration(0), configuration(1), configuration(2), configuration(1, "test") ].map do |config|
        Resources.new(resident, instance: config)
      end
      names = resources.flat_map { |r| [ r.container, *r.volumes.values ] }
      assert_equal names.length, names.uniq.length
      assert_equal "hk-agent-test-resident-uuid", resources.first.container
      assert_equal "chaos-home-test-resident-uuid", resources.first.volumes[:chaos]
    end

    test "stored foreign names are rejected before any Docker access" do
      agent = resident
      agent.container_name = Resources.new(agent, instance: configuration(1)).container
      target = Resources.new(agent, instance: configuration(2))
      assert_raises(Resources::OwnershipError) { target.verify_existing! }
    end

    test "missing ownership labels cannot be silently adopted" do
      resource = Resources.new(resident, instance: configuration(1))
      success = Struct.new(:success?).new(true)
      DockerLocalGuard.stub(:check!, true) do
        Open3.stub(:capture3, [ "<no value>\n", "", success ]) do
          assert_raises(Resources::OwnershipError) { resource.verify_existing! }
        end
      end
    end

    test "remote Docker endpoints are refused" do
      previous_host, previous_context = ENV.values_at("DOCKER_HOST", "DOCKER_CONTEXT")
      ENV["DOCKER_HOST"] = "ssh://remote"
      ENV.delete("DOCKER_CONTEXT")
      assert_raises(Resources::OwnershipError) { DockerLocalGuard.check! }
    ensure
      ENV["DOCKER_HOST"], ENV["DOCKER_CONTEXT"] = previous_host, previous_context
    end

  end
end
