require "test_helper"

class Agents::VmMigration::RollbackRestoreTest < ActiveSupport::TestCase
  ID = "0" * 63 + "1"

  test "every restore verifies what it wrote into the destination" do
    Agents::VmMigration::RollbackPlan::ROLES.each do |role|
      args = Agents::VmMigration::RollbackRestore.args(ID, role)

      assert_equal [ "restore", "#{ID}:/rollback/#{role}", "--target", "/rollback/#{role}", "--verify" ], args
      assert Agents::VmMigration::RollbackRestore.verified_args?(args)
    end
    assert_not Agents::VmMigration::RollbackRestore.verified_args?(%w[restore x --target /y])
  end

  test "refuses a short snapshot id or an unknown role" do
    assert_raises(ArgumentError) { Agents::VmMigration::RollbackRestore.args("abc123", :chaos) }
    assert_raises(ArgumentError) { Agents::VmMigration::RollbackRestore.args(ID, :home) }
  end
end
