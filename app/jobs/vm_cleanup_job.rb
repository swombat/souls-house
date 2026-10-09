# Removes the server of a placement whose cleanup was requested (#246 slice
# 5), and keeps going until the provider confirms nothing is left:
#
#   * a purchase whose outcome is unknown keeps being reconciled; a server that
#     turns up is deleted
#   * a verified server is deleted, and deletion is reconciled until absent
#   * once every purchase is refused or deleted, the runner enrollment is
#     revoked and the placement retired, which releases its slot in the cap
#
# A purchase that needs review and never showed a server is left for an
# operator: nothing here can prove it bought nothing, so the placement stays
# counted against the cap. VmBirthSweepJob runs this every minute until the
# placement is retired; every run reads current state.
class VmCleanupJob < ApplicationJob

  queue_as :default

  def perform(placement_id)
    # The same lifecycle lock as the birth: cleanup and a birth step for one
    # placement never run at once, and a delete is never sent twice at once.
    ProvisionVmAgentJob.exclusively(placement_id) { clean(placement_id) }
  end

  private

  def clean(placement_id)
    placement = AgentPlacement.find_by(id: placement_id)
    return if placement.nil? || !placement.cleanup_requested?
    # Retired, but a transient failure may have interrupted the release.
    return release_backup_holds(placement) if placement.state == "retired"

    procurement = ProvisionVmAgentJob.procurement_factory.call
    placement.cloud_procurement_operations.unresolved.order(:id).each { |operation| procurement.cleanup!(operation) }

    unresolved = placement.cloud_procurement_operations.unresolved.reload.to_a
    return retire!(placement) if unresolved.empty?

    if unresolved.all? { |operation| operation.state == "needs_review" && operation.provider_server_id.nil? }
      Rails.logger.warn("[vm_cleanup] placement=#{placement.id} needs an operator: " \
                        "#{unresolved.map { |o| "#{o.public_id}:#{o.review_reason}" }.join(', ')}")
    end
  rescue StandardError => e
    # Tried again by the next sweep.
    Rails.logger.error("[vm_cleanup] placement=#{placement_id} error, will retry: #{e.class}: #{e.message}")
  end

  # The empty read above is not the confirmation: it is checked again under
  # the placement lock, where nothing new can be ordered for it.
  def retire!(placement)
    retired = placement.transaction do
      placement.lock!
      next false if placement.cloud_procurement_operations.unresolved.exists?

      RunnerEnrollment.where(agent_placement_id: placement.id, revoked_at: nil).find_each(&:revoke!)
      placement.update!(state: "retired", provider_server_id: nil, location: nil)
      true
    end
    release_backup_holds(placement) if retired
  end

  # Slice 4 keeps a backup hold whose outcome is unknown until nothing of the
  # VM is left; once that is confirmed, it can let go. Safe to repeat.
  def release_backup_holds(placement)
    return unless Backup.const_defined?(:VmResident) && Backup::VmResident.respond_to?(:release_after_retirement!)

    Backup::VmResident.release_after_retirement!(placement:)
  end

end
