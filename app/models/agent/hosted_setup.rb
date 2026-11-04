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
  #
  # Same lock order as AgentServiceAccess#change_send_grant!: the connection,
  # then the access row, read fresh under both. Without it a disable that
  # loaded can_send = false before a concurrent grant committed would save
  # enabled = false over can_send = true (only changed columns are written),
  # and re-enabling read would then revive the grant.
  # Authority and connection status must also be read under these locks.
  # A resident's own API has the additional restriction that it may manage
  # only connections it set up, not every connection its key's person owns.
  #
  # A guest (the connection lives in an account where this resident has a
  # seat, JWblqj) is switched on by the connection's owner, or by whoever can
  # provision an account-wide one, and gets nothing until its home approves:
  # the row is born pending. Switching it off voids the approval. The seat is
  # held FOR SHARE under the connection's lock, so a departure in flight
  # (GuestMembership#close_seats, which locks the seat FOR UPDATE and then
  # destroys these rows) either finishes first and this is refused, or waits
  # for this to commit and then removes what it granted.
  def set_service_access!(connection, enabled:, actor: Current.user, resident_actor: nil)
    enabled = ActiveModel::Type::Boolean.new.cast(enabled)
    connection.transaction do
      connection.lock!
      guest = account_id != connection.account_id
      if guest
        # A resident's own key manages its home's connections only.
        raise ActiveRecord::RecordNotFound if resident_actor

        seat = GuestMembership.lock("FOR SHARE").find_by(agent_id: id, account_id: connection.account_id)
        raise AgentServiceAccess::ReadGrantRefused.new("#{name} is not a guest in this account", status: :not_found) unless seat
      end
      access = AgentServiceAccess.lock.find_by(agent_id: id, service_connection_id: connection.id) ||
        agent_service_accesses.build(service_connection: connection)
      if resident_actor && !connection.resident_managed_by?(resident_actor)
        raise ActiveRecord::RecordNotFound
      end
      allowed = guest ? connection.guest_access_changeable_by?(actor, enabled: enabled) : connection.resident_access_changeable_by?(actor, enabled: enabled)
      unless allowed
        message = if guest && enabled && connection.personal?
          "Only the connection's owner can share it with a guest"
        else
          "You cannot change this resident's access"
        end
        raise AgentServiceAccess::ReadGrantRefused, message
      end
      if enabled && connection.status != "connected"
        raise AgentServiceAccess::ReadGrantRefused.new(
          "Reconnect this service before enabling resident access", status: :conflict
        )
      end
      access.send_grant_actor = actor
      if guest
        access.follows_default = false
        if enabled
          # Already asked or already approved: nothing to re-ask.
          next access if access.persisted? && access.enabled? && access.home_approval.in?(AgentServiceAccess::OPEN_HOME_APPROVALS)

          access.provisioning_status = "pending"
          next access.request_home_approval!(actor: actor)
        end

        access.provisioning_status = "removal_pending"
        next access.withdraw_home_approval!(actor: actor)
      end
      access.enabled = enabled
      access.follows_default = false
      access.provisioning_status = enabled ? "pending" : "removal_pending"
      access.save!
      access
    end
  end

end
