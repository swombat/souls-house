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

  after_save :refresh_integration_status, if: :integration_status_changed?
  after_destroy :refresh_integration_status

  INTEGRATION_STATUS_COLUMNS = %w[
    agent_id service_connection_id enabled follows_default
    provisioning_status provisioning_error_code
  ].freeze

  def schedule_reconciliation!
    return unless agent&.externally_hosted? && agent.container_name.present?

    if persisted?
      status = enabled? ? "pending" : "removal_pending"
      changed = provisioning_status != status || provisioning_error_code.present?
      written = update_columns(
        provisioning_status: status,
        provisioning_error_code: nil,
        updated_at: Time.current
      )
      refresh_integration_status if written && changed
    end
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

  def integration_status_changed?
    previously_new_record? || (saved_changes.keys & INTEGRATION_STATUS_COLUMNS).any?
  end

  def refresh_integration_status
    agent_ids = [ agent_id, *saved_change_to_agent_id ].compact
    connection_ids = [ service_connection_id, *saved_change_to_service_connection_id ].compact
    IntegrationStatus.refresh!(
      Agent.where(id: agent_ids).pluck(:account_id) +
        ServiceConnection.where(id: connection_ids).pluck(:account_id)
    )
  end

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
