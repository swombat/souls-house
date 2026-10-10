require "test_helper"

class DeployAlarmCheckJobTest < ActiveJob::TestCase

  test "runs the check" do
    called = false
    DeployAlarm.stub(:check!, -> { called = true }) { DeployAlarmCheckJob.perform_now }
    assert called
  end

  test "is scheduled every 5 minutes in production" do
    schedule = YAML.load_file(Rails.root.join("config/recurring.yml"), aliases: true).dig("production", "deploy_alarm_check")
    assert_equal "DeployAlarmCheckJob", schedule["class"]
    assert_equal "every 5 minutes", schedule["schedule"]
  end

end
