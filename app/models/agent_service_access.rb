class AgentServiceAccess < ApplicationRecord

  belongs_to :agent
  belongs_to :service_connection

  validates :service_connection_id, uniqueness: { scope: :agent_id }
  validate :same_account

  scope :enabled, -> { where(enabled: true) }

  # Commit callbacks are deduplicated by filter name. Keep distinct wrapper
  # methods here so create, update, and destroy reconciliation all survive.
  after_create_commit :schedule_reconciliation_after_create!
  after_update_commit :schedule_reconciliation_after_update!, if: :saved_change_to_enabled?
  after_destroy_commit :schedule_reconciliation_after_destroy!

  def schedule_reconciliation!
    return unless agent&.externally_hosted? && agent.container_name.present?

    update_columns(
      provisioning_status: enabled? ? "pending" : "removal_pending",
      provisioning_error_code: nil,
      updated_at: Time.current
    ) if persisted?
    AccountAgentCredentialsRefreshJob.perform_later(agent.account_id, agent.id, manifest_only: true)
  end

  def mark_provisioned!
    update!(
      provisioned_revision: service_connection.credential_revision,
      provisioned_at: Time.current,
      provisioning_status: "provisioned",
      provisioning_error_code: nil
    )
  end

  private

  def schedule_reconciliation_after_create!
    schedule_reconciliation!
  end

  def schedule_reconciliation_after_update!
    schedule_reconciliation!
  end

  def schedule_reconciliation_after_destroy!
    schedule_reconciliation!
  end

  def same_account
    return unless agent && service_connection
    errors.add(:service_connection, "must belong to the resident's account") unless agent.account_id == service_connection.account_id
  end

end
