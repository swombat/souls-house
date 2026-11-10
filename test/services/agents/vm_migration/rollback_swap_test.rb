require "test_helper"

class Agents::VmMigration::RollbackSwapTest < ActiveSupport::TestCase
  setup do
    @agent = agents(:research_assistant)
    @agent.update_columns(uuid: "55555555-5555-4555-8555-555555555555", volume_map: nil, volume_rollback_generation: 0)
    @plan = Agents::VmMigration::RollbackPlan.new(@agent, generation: 1)
    @all = Agents::VmMigration::RollbackPlan::ROLES.index_with(true)
  end

  def swap(**options)
    Agents::VmMigration::RollbackSwap.new(@agent, plan: @plan, verified: @all, **options).call
  end

  test "commits the fresh map with its receipt, then starts the resident" do
    started = nil
    outcome = swap(start: ->(agent) { started = agent.reload.volume_map })

    assert outcome.ok?
    assert_equal @plan.fresh_map, @agent.reload.volume_map
    assert_equal @plan.fresh_map, started
    assert_equal Agents::Resources.new(@agent).derived_volumes.values.map { |n| "#{n}-rb1" }, Agents::Resources.new(@agent).volumes.values
    receipt = AuditLog.where(action: "vm_rollback_swap", auditable: @agent).last
    assert_nil receipt.data["previous_map"]
    assert_equal @plan.fresh_map, receipt.data["volume_map"]
  end

  test "an unverified role fails before the commit and changes nothing" do
    assert_no_difference -> { AuditLog.where(action: "vm_rollback_swap").count } do
      outcome = Agents::VmMigration::RollbackSwap.new(@agent, plan: @plan, verified: @all.merge(work: false)).call
      assert_equal :before_commit, outcome.phase
      assert_match "work", outcome.error
    end
    assert_nil @agent.reload.volume_map
  end

  test "a failure inside the commit (the placement switch) rolls the map back too" do
    outcome = swap(in_commit: ->(_agent) { raise "placement refused" })

    assert_equal :before_commit, outcome.phase
    assert_nil @agent.reload.volume_map
    assert_not AuditLog.exists?(action: "vm_rollback_swap", auditable: @agent)
  end

  test "a map changed under the rollback is not overwritten" do
    other = Agents::Resources.new(@agent).derived_volumes.transform_keys(&:to_s).transform_values { |n| "#{n}-rb9" }
    Agent.where(id: @agent.id).update_all(volume_map: other)

    outcome = swap
    assert_equal :before_commit, outcome.phase
    assert_equal other, @agent.reload.volume_map
  end

  test "a failed start is after the commit: the map stays, the receipt keeps the old one, and revert is explicit" do
    outcome = swap(start: ->(_agent) { raise "container did not start" })

    assert_equal :after_commit, outcome.phase
    assert_equal @plan.fresh_map, @agent.reload.volume_map

    Agents::VmMigration::RollbackSwap.revert!(@agent, previous_map: outcome.previous_map, fresh_map: outcome.fresh_map)
    assert_nil @agent.reload.volume_map
    assert AuditLog.exists?(action: "vm_rollback_revert", auditable: @agent)
    assert_raises(Agents::VmMigration::RollbackSwap::Failed) do
      Agents::VmMigration::RollbackSwap.revert!(@agent, previous_map: outcome.previous_map, fresh_map: outcome.fresh_map)
    end
  end
end
