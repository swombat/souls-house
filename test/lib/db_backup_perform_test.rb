require "test_helper"
require "rake"

class DbBackupPerformTest < ActiveSupport::TestCase

  setup do
    @previous_rake = Rake.application
    Rake.application = Rake::Application.new
    load Rails.root.join("lib/tasks/db_backup.rake")
    @task = Rake::Task["db_backup:perform"]
  end

  teardown do
    Rake.application = @previous_rake
  end

  test "manual backup uses the house-aware binstub and fails fast" do
    commands = []
    run = ->(*arguments) { commands << arguments; true }

    @task.actions.first.binding.receiver.stub(:system, run) do
      capture_io { @task.invoke }
    end

    assert_equal [
      [ "bin/kamal", "app", "exec", "-r", "web",
        "bin/rails runner 'FullBackupJob.perform_now(fail_fast: true)'" ]
    ], commands
    assert_empty @task.prerequisites
  end

  test "manual backup reports a failed production command" do
    @task.actions.first.binding.receiver.stub(:system, false) do
      _output, error = capture_io do
        failure = assert_raises(SystemExit) { @task.invoke }
        assert_not_equal 0, failure.status
      end
      assert_includes error, "Production backup failed."
    end
  end

end
