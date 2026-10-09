module Backup
  class VmBackupCheckJob < ApplicationJob

    queue_as :default

    def perform(command_id)
      result = VmResident.status(command: RunnerCommand.find(command_id))
      self.class.set(wait: 15.seconds).perform_later(command_id) if result[:state] == "pending"
    end

  end
end
