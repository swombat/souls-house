# Every 5 minutes in production: does production still follow master?
class DeployAlarmCheckJob < ApplicationJob

  queue_as :default

  def perform
    DeployAlarm.check!
  end

end
