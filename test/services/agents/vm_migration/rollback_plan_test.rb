require "test_helper"

class Agents::VmMigration::RollbackPlanTest < ActiveSupport::TestCase
  FakeResources = Struct.new(:volumes)

  LIVE = {
    identity: "hk-agent-u1-identity", chaos: "chaos-home-u1", repo: "hk-agent-u1-repo",
    work: "hk-agent-u1-work", state: "hk-agent-u1-state"
  }.freeze

  def plan(generation: 2, volumes: LIVE)
    Agents::VmMigration::RollbackPlan.new(nil, generation:, resources: FakeResources.new(volumes))
  end

  test "names a fresh volume for every one of the five roles, never a live one" do
    targets = plan.targets

    assert_equal %i[identity chaos repo work state], targets.map(&:role)
    assert_equal LIVE.values, targets.map(&:live)
    assert_equal "chaos-home-u1-rb2", targets.find { |t| t.role == :chaos }.fresh
    assert_empty targets.map(&:fresh) & LIVE.values
  end

  test "refuses when a fresh name would be a live volume" do
    volumes = LIVE.merge(work: "hk-agent-u1-repo-rb2")

    error = assert_raises(Agents::VmMigration::RollbackPlan::Unsafe) { plan(volumes:).targets }
    assert_match "hk-agent-u1-repo-rb2", error.message
  end

  test "refuses a volume map that is not exactly the five roles" do
    assert_raises(Agents::VmMigration::RollbackPlan::Unsafe) { plan(volumes: LIVE.except(:work)).targets }
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
end
