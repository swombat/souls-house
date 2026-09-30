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

    test "hostname is stable, per resident, valid, and never a personal machine name" do
      uuid = "0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b"
      first = Resources.new(Struct.new(:uuid, :container_name).new(uuid, nil), instance: configuration(0)).hostname
      again = Resources.new(Struct.new(:uuid, :container_name).new(uuid, "hk-agent-#{uuid}"), instance: configuration(0)).hostname
      other = Resources.new(Struct.new(:uuid, :container_name).new("0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5c", nil), instance: configuration(0)).hostname
      assert_equal "souls-house-#{uuid}", first
      assert_equal first, again
      assert_not_equal first, other
      assert_operator first.length, :<=, 63
      assert_match(/\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\z/, first)
      assert_not_includes %w[danbook omarchidell localhost], first
      assert_equal "souls-house-abcdef", Resources.new(Struct.new(:uuid, :container_name).new("ABCDEF", nil), instance: configuration(0)).hostname
    end

    test "an identifier that cannot form a hostname is refused" do
      [ "has_underscore", "trailing-", "x" * 60 ].each do |uuid|
        resources = Resources.new(Struct.new(:uuid, :container_name).new(uuid, nil), instance: configuration(0))
        assert_raises(ArgumentError, uuid) { resources.hostname }
      end
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
