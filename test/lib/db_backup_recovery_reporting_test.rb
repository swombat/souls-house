require "test_helper"
require "rake"

class DbBackupRecoveryReportingTest < ActiveSupport::TestCase

  test "fleet task reports partial recovery after attempting the whole mocked batch" do
    previous = Rake.application
    Rake.application = Rake::Application.new
    Rake::Task.define_task(:environment)
    load Rails.root.join("lib/tasks/db_backup.rake")
    results = { 1 => { restored: false }, 2 => { restored: true, awake: true },
      3 => { restored: true, awake: false, memory_mismatch: true } }
    # This tests reporting only. No guard bypass reaches Docker, S3 or a
    # resident: the entire fleet operation is replaced by a synthetic result.
    Rails.stub(:env, ActiveSupport::StringInquirer.new("development")) do
      DbBackupHelpers.stub(:ensure_not_production!, true) do
        DbBackupHelpers.stub(:refreshing?, true) do
          Backup::AgentResticRestore.stub(:restore_all!, results) do
            output, error = capture_io do
              exit_error = assert_raises(SystemExit) { Rake::Task["db_backup:restore_agents"].invoke }
              assert_not_equal 0, exit_error.status
            end
            assert_includes output, "2/3 filesets restored; 1 residents woken"
            assert_includes error, "agent IDs: 1, 3"
          end
        end
      end
    end
  ensure
    Rake.application = previous
  end

end
