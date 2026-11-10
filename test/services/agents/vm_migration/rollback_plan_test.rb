require "test_helper"

class Agents::VmMigration::RollbackPlanTest < ActiveSupport::TestCase
  FakeResources = Struct.new(:volumes, :derived_volumes, :labels)
  Status = Struct.new(:ok) do
    def success? = ok
  end

  LIVE = {
    identity: "hk-agent-u1-identity", chaos: "chaos-home-u1", repo: "hk-agent-u1-repo",
    work: "hk-agent-u1-work", state: "hk-agent-u1-state"
  }.freeze

  def plan(generation: 2, volumes: LIVE, derived: LIVE, agent: Struct.new(:uuid).new("u1"))
    Agents::VmMigration::RollbackPlan.new(agent, generation:, resources: FakeResources.new(volumes, derived, []))
  end

  # A Docker double: volumes is the set that exists; create adds a name with
  # the label it was given unless `racer` already put one there first.
  class FakeDocker
    attr_reader :volumes, :calls

    def initialize(existing: {}, racer: {})
      @volumes = existing.dup
      @racer = racer
      @calls = []
    end

    def call(*argv)
      @calls << argv
      _docker, _volume, verb = argv
      name = argv.last
      case verb
      when "inspect"
        return [ "", "Error: No such volume: #{name}", Status.new(false) ] unless @volumes.key?(name)
        [ "#{@volumes[name]}\n", "", Status.new(true) ]
      when "create"
        label = argv[argv.index("--label") + 1].split("=", 2).last
        @volumes[name] ||= @racer.fetch(name, label)
        [ "#{name}\n", "", Status.new(true) ]
      end
    end
  end

  test "names a fresh volume for every one of the five roles, never a live one" do
    targets = plan.targets

    assert_equal %i[identity chaos repo work state], targets.map(&:role)
    assert_equal LIVE.values, targets.map(&:live)
    assert_equal "chaos-home-u1-rb2", targets.find { |t| t.role == :chaos }.fresh
    assert_empty targets.map(&:fresh) & LIVE.values
  end

  test "fresh names come from the derived names even when the resident runs on an earlier rollback" do
    live = LIVE.transform_values { |name| "#{name}-rb1" }
    targets = plan(volumes: live).targets

    assert_equal LIVE.values.map { |name| "#{name}-rb2" }, targets.map(&:fresh)
    assert_equal live.values, targets.map(&:live)
  end

  test "refuses when a fresh name would be a live volume" do
    volumes = LIVE.merge(work: "hk-agent-u1-repo-rb2")

    error = assert_raises(Agents::VmMigration::RollbackPlan::Unsafe) { plan(volumes:).targets }
    assert_match "hk-agent-u1-repo-rb2", error.message
  end

  test "refuses a live map that names one volume for two roles" do
    error = assert_raises(Agents::VmMigration::RollbackPlan::Unsafe) { plan(volumes: LIVE.merge(work: LIVE[:repo])).targets }
    assert_match "two roles", error.message
  end

  test "refuses a volume map that is not exactly the five roles" do
    assert_raises(Agents::VmMigration::RollbackPlan::Unsafe) { plan(volumes: LIVE.except(:work)).targets }
    assert_raises(Agents::VmMigration::RollbackPlan::Unsafe) { plan(volumes: LIVE.merge(extra: "x")).targets }
  end

  test "refuses to reuse fresh volumes left by an earlier attempt" do
    leftover = "hk-agent-u1-state-rb2"

    error = assert_raises(Agents::VmMigration::RollbackPlan::Unsafe) do
      plan.check_fresh_absent!(exists: ->(name) { name == leftover })
    end
    assert_match leftover, error.message
    assert plan.check_fresh_absent!(exists: ->(_) { false })
  end

  test "requires a positive generation" do
    assert_raises(ArgumentError) { plan(generation: 0) }
  end

  test "allocate creates five labelled volumes and reads each label back" do
    docker = FakeDocker.new
    nonce = "a" * 32

    plan.allocate!(docker:, nonce:)

    assert_equal LIVE.values.map { |name| "#{name}-rb2" }.sort, docker.volumes.keys.sort
    assert docker.volumes.values.all?("u1/2/#{nonce}")
    assert_equal 5, docker.calls.count { |argv| argv[2] == "create" }
  end

  test "allocate creates nothing when any fresh name already exists" do
    docker = FakeDocker.new(existing: { "hk-agent-u1-work-rb2" => "u1/2/#{'b' * 32}" })

    assert_raises(Agents::VmMigration::RollbackPlan::Unsafe) { plan.allocate!(docker:, nonce: "a" * 32) }
    assert_equal 0, docker.calls.count { |argv| argv[2] == "create" }
  end

  test "allocate refuses a volume another process created between the check and the create" do
    docker = FakeDocker.new(racer: { "hk-agent-u1-repo-rb2" => "u1/2/#{'c' * 32}" })

    error = assert_raises(Agents::VmMigration::RollbackPlan::Unsafe) { plan.allocate!(docker:, nonce: "a" * 32) }
    assert_match "hk-agent-u1-repo-rb2", error.message
  end

  test "allocate refuses when it cannot tell whether a volume exists" do
    docker = Object.new
    def docker.call(*) = [ "", "permission denied", Status.new(false) ]

    assert_raises(Agents::VmMigration::RollbackPlan::Unsafe) { plan.allocate!(docker:, nonce: "a" * 32) }
  end

  test "reserve hands out a rising generation that is never reused" do
    agent = agents(:research_assistant)
    agent.update_columns(volume_rollback_generation: 0)

    assert_equal 1, Agents::VmMigration::RollbackPlan.reserve!(agent)
    assert_equal 2, Agents::VmMigration::RollbackPlan.reserve!(agent.reload)
    assert_equal 3, Agents::VmMigration::RollbackPlan.reserve!(Agent.find(agent.id))
    assert_equal 3, agent.reload.volume_rollback_generation
  end
end
