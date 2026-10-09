# What a person can do to a resident's settings and hosted setup, shared by the
# web resident pages and the human-key API.
module Agent::HostedSetup

  extend ActiveSupport::Concern

  # Settings and house-inference funding change together.
  def update_settings!(attributes, by:)
    HouseInferenceGrant.synchronize do
      update!(attributes)
      HouseInferenceGrant.assign!(self, by)
    end
  end

  def provisioning_retryable?
    born_hosted? && provisioning?
  end

  # Keeps the committed seed and any identity volume; only the infrastructure
  # step runs again.
  def retry_provisioning!
    update!(
      provisioning_started_at: Time.current,
      sandbox_last_error: nil,
      sandbox_last_error_at: nil,
      health_state: "unknown"
    )
    ProvisionAgentJob.perform_later(id)
  end

  def orientation_retryable?
    born_hosted? && external? && health_state == "healthy"
  end

  def retry_orientation!
    update!(
      orientation_completed_at: nil,
      orientation_last_error: nil,
      orientation_last_error_at: nil
    )
    OrientNewAgentJob.perform_later(id)
  end

  # A person switching this resident's use of one of the account's service
  # connections. Provisioning happens asynchronously.
  # Disabling also withdraws any send grant, and enabling never restores one
  # (AgentServiceAccess#withdraw_send_when_disabled).
  def set_service_access!(connection, enabled:, actor: Current.user)
    access = agent_service_accesses.find_or_initialize_by(service_connection: connection)
    access.send_grant_actor = actor
    access.enabled = enabled
    access.follows_default = false
    access.provisioning_status = enabled ? "pending" : "removal_pending"
    access.save!
    access
  end

end
