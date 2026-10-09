class AgentServiceAccess < ApplicationRecord

  # Why a send grant was withdrawn, for the owner's grant history.
  SEND_WITHDRAWAL_REASONS = %w[withdrawn access_disabled disconnected repaired owner_changed].freeze

  class SendGrantRefused < StandardError; end

  belongs_to :agent
  belongs_to :service_connection

  # Who is changing this row, when a person is (set by set_service_access!
  # and change_send_grant!). Recorded in the send grant history.
  attr_accessor :send_grant_actor

  validates :service_connection_id, uniqueness: { scope: :agent_id }
  validate :same_account
  validate :can_send_only_with_enabled_comms_access

  scope :enabled, -> { where(enabled: true) }
  scope :sending, -> { enabled.where(can_send: true) }

  # No revival (spec §5): set_service_access! reuses this row and changes
  # only `enabled`, so a disabled row must lose can_send here, whoever
  # disables it. Re-enabling read never restores it.
  before_validation :withdraw_send_when_disabled
  before_save :withdraw_send_when_disabled
  after_save :record_send_withdrawal_on_disable

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
    AccountAgentCredentialsRefreshJob.perform_later(agent.account_id, agent.id)
  end

  def mark_provisioned!
    update!(
      provisioned_revision: service_connection.credential_revision,
      provisioned_at: Time.current,
      provisioning_status: "provisioned",
      provisioning_error_code: nil
    )
  end

  # Grants or withdraws sending as the connection's owner. Only the owner can
  # grant (speaking as a person is that person's grant to give); anyone who
  # can manage the connection can withdraw. Every change is recorded.
  def change_send_grant!(can_send, actor:)
    can_send = ActiveModel::Type::Boolean.new.cast(can_send)
    unless service_connection.send_grant_changeable_by?(actor, can_send: can_send)
      raise SendGrantRefused, can_send ? "Only the connection's owner can let a resident send" : "You cannot manage this connection"
    end

    with_lock do
      next if self.can_send == can_send

      if can_send
        raise SendGrantRefused, "Enable this resident's access first" unless enabled?
        raise SendGrantRefused, "This connection cannot send" unless service_connection.credential_strategy == "connector"
        raise SendGrantRefused, "Reconnect this service before letting a resident send" unless service_connection.status == "connected"
      end
      update!(can_send: can_send)
      CommsSendGrantEvent.record!(self, granted: can_send, actor: actor, reason: can_send ? "granted" : "withdrawn")
    end
    self
  end

  private

  def withdraw_send_when_disabled
    return unless !enabled? && can_send?

    self.can_send = false
    @send_withdrawn_by_disable = persisted? && can_send_in_database
  end

  def record_send_withdrawal_on_disable
    return unless @send_withdrawn_by_disable

    @send_withdrawn_by_disable = false
    CommsSendGrantEvent.record!(self, granted: false, actor: send_grant_actor || Current.user, reason: "access_disabled")
  end

  def can_send_only_with_enabled_comms_access
    return unless can_send?

    errors.add(:can_send, "needs enabled access") unless enabled?
    errors.add(:can_send, "is only for comms connections") unless service_connection&.credential_strategy == "connector"
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
