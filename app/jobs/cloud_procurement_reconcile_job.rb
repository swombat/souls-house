# Reconciles one procurement operation and, while it is still settling,
# checks again later. Never creates a server: only submit! does that, once.
class CloudProcurementReconcileJob < ApplicationJob

  queue_as :default

  SETTLING_STATES = %w[create_in_flight unknown reconciling deleting].freeze
  RECHECK_AFTER = 1.minute

  def perform(operation_id)
    operation = CloudProcurementOperation.find_by(id: operation_id)
    return if operation.nil?

    operation = CloudProcurement.from_credentials.reconcile!(operation)
    self.class.set(wait: RECHECK_AFTER).perform_later(operation.id) if SETTLING_STATES.include?(operation.state)
  end

end
