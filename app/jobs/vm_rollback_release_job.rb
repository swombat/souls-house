# Releases the server a recovered rollback left behind (#426 release_vm!).
# VmBirthSweepJob enqueues it every minute until the release is confirmed, so
# a pass that finds the provider still deleting, or the attempt not yet
# recovered, simply ends.
class VmRollbackReleaseJob < ApplicationJob

  queue_as :default

  def perform(rollback_id)
    rollback = VmRollback.find_by(id: rollback_id)
    return if rollback.nil? || rollback.released? || !rollback.release_requested?

    Agents::VmMigration::RollbackRelease.new(rollback).step!
  rescue CloudProcurement::NotAllowed, HetznerCloudClient::Error => e
    # Tried again by the next sweep.
    Rails.logger.error("[vm_rollback_release] rollback=#{rollback_id} error, will retry: #{e.class}: #{e.message}")
  end

end
