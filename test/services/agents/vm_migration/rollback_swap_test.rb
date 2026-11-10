require "test_helper"

class Agents::VmMigration::RollbackSwapTest < ActiveSupport::TestCase
  # The swap refuses to run inside any open transaction, so these tests run
  # outside transactional fixtures, as the swap will in production.
  self.use_transactional_tests = false

  setup do
    @agent = agents(:research_assistant)
    @agent.update_columns(uuid: "55555555-5555-4555-8555-555555555555", volume_map: nil, volume_rollback_generation: 0)
    @plan = Agents::VmMigration::RollbackPlan.new(@agent, generation: 1)
    @all = Agents::VmMigration::RollbackPlan::ROLES.index_with(true)
  end

  teardown do
    AuditLog.where(auditable: @agent).delete_all
    @agent.update_columns(volume_map: nil, volume_rollback_generation: 0)
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

  test "an old plan never replaces a newer rollback's map, even after the agent is reloaded" do
    old_plan = @plan
    newer = Agents::Resources.new(@agent).derived_volumes.transform_keys(&:to_s).transform_values { |n| "#{n}-rb2" }
    Agent.where(id: @agent.id).update_all(volume_map: newer)
    @agent.reload
    started = false

    outcome = Agents::VmMigration::RollbackSwap.new(@agent, plan: old_plan, verified: @all, start: ->(_) { started = true }).call

    assert_equal :before_commit, outcome.phase
    assert_not started
    assert_equal newer, @agent.reload.volume_map
    assert_not AuditLog.exists?(action: "vm_rollback_swap", auditable: @agent)
  end

  test "a swallowed ActiveRecord::Rollback inside the commit is not an after_commit, and start never runs" do
    started = false
    outcome = swap(in_commit: ->(_agent) { raise ActiveRecord::Rollback }, start: ->(_) { started = true })

    assert_equal :before_commit, outcome.phase
    assert_not started
    assert_nil @agent.reload.volume_map
    assert_not AuditLog.exists?(action: "vm_rollback_swap", auditable: @agent)
  end

  test "inside an enclosing transaction the swap refuses before committing anything" do
    started = false
    outcome = nil
    Agent.transaction do
      outcome = swap(start: ->(_) { started = true })
    end

    assert_equal :before_commit, outcome.phase
    assert_match "open transaction", outcome.error
    assert_not started
    assert_nil @agent.reload.volume_map
  end

  test "inside a non-joinable enclosing transaction the swap also refuses" do
    started = false
    outcome = nil
    Agent.transaction(joinable: false) do
      outcome = swap(start: ->(_) { started = true })
    end

    assert_equal :before_commit, outcome.phase
    assert_match "open transaction", outcome.error
    assert_not started
    assert_nil @agent.reload.volume_map
    assert_not AuditLog.exists?(action: "vm_rollback_swap", auditable: @agent)
  end

  test "after a swap and a revert, retrying the same plan never reaches start" do
    first = swap
    assert first.ok?
    Agents::VmMigration::RollbackSwap.revert!(@agent, previous_map: first.previous_map, fresh_map: first.fresh_map)
    assert_nil @agent.reload.volume_map

    started = false
    retried = swap(in_commit: ->(_agent) { raise ActiveRecord::Rollback }, start: ->(_) { started = true })
    assert_equal :before_commit, retried.phase
    assert_not started
    assert_nil @agent.reload.volume_map

    again = swap(start: ->(_) { started = true })
    assert_equal :before_commit, again.phase
    assert_match "already been swapped", again.error
    assert_not started
    assert_nil @agent.reload.volume_map
    assert_equal 1, AuditLog.where(action: "vm_rollback_swap", auditable: @agent).count
  end

  test "an error raised after the database commit is after_commit, and start never runs" do
    started = false
    outcome = swap(in_commit: ->(_agent) { ActiveRecord::Base.current_transaction.after_commit { raise "hook failed" } },
      start: ->(_) { started = true })

    assert_equal :after_commit, outcome.phase
    assert_match "hook failed", outcome.error
    assert_not started
    assert_equal @plan.fresh_map, @agent.reload.volume_map
    assert AuditLog.exists?(action: "vm_rollback_swap", auditable: @agent)
  end
end
