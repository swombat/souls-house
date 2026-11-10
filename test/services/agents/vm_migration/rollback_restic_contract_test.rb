require "test_helper"

# The real-restic check in test/host_runner/rollback_verify_test.py runs the
# invocation in this fixture against the pinned image. This test keeps the
# fixture and the code the same thing, so that check is about what ships.
class Agents::VmMigration::RollbackResticContractTest < ActiveSupport::TestCase
  CONTRACT = JSON.parse(File.read(Rails.root.join("test/fixtures/files/rollback_restic_contract.json")))

  test "the image, flags and roles are the ones the executor uses" do
    assert_equal Agents::VmMigration::RollbackHome::IMAGE, CONTRACT.fetch("image")
    assert_equal Agents::VmMigration::RollbackHome::RESTIC_FLAGS, CONTRACT.fetch("flags")
    assert_equal Agents::VmMigration::RollbackPlan::ROLES.map(&:to_s), CONTRACT.fetch("roles")
  end

  test "the restore arguments for every role are the fixture's" do
    snapshot = "a" * 64
    CONTRACT.fetch("roles").each do |role|
      expected = CONTRACT.fetch("restore").map { |arg| arg.gsub("{snapshot}", snapshot).gsub("{role}", role) }
      assert_equal expected, Agents::VmMigration::RollbackRestore.args(snapshot, role)
    end
  end

  test "no overwrite mode is passed: only the default rewrites a same-size file and verifies it" do
    # Measured on the pinned 0.18.1: --overwrite never / if-changed skip a
    # same-size file, and --verify then checks only what was written.
    refute CONTRACT.fetch("restore").any? { |arg| arg.start_with?("--overwrite") }
  end
end
