class AccountAgentCredentialsRefreshJob < ApplicationJob

  queue_as :default

  retry_on Agents::Sandbox::SandboxError, wait: 5.minutes, attempts: 3

  def perform(account_id, agent_id = nil)
    account = Account.find(account_id)
    scope = account.agents.externally_hosted
    scope = scope.where(id: agent_id) if agent_id.present?

    scope.where.not(container_name: nil).find_each do |agent|
      if Agents::RemoteRuntime.remote?(agent)
        refresh_remote!(account, agent)
        next
      end

      sandbox = Agents::Sandbox.new(agent)

      if sandbox.active_turn?
        self.class.set(wait: 5.minutes).perform_later(account.id, agent.id)
      else
        sandbox.recreate!
        mark_service_accesses_reconciled!(agent)
      end
    end
  end

  private

  # A resident on its own VM gets new keys and services the way a local one
  # does: a start with the current environment and manifest, which the runner
  # turns into a recreated container. Only between turns (checked in the
  # house's own records under the turn gate, never by inspecting Docker), not
  # while a VM backup holds the resident, and not before a VM birth has
  # finished (the birth's own start carries the current values). Services are
  # marked reconciled only when the restart is confirmed (RemoteRefreshSettleJob).
  def refresh_remote!(account, agent)
    return unless Agents::RemoteRuntime.running?(agent)
    return defer!(account, agent) if vm_backup_holding?(agent)

    result = Agents::RemoteRuntime.begin_refresh!(agent)
    return defer!(account, agent) if result == :busy

    RemoteRefreshSettleJob.set(wait: RemoteRefreshSettleJob::RECHECK_AFTER).perform_later(agent.placement.id)
  end

  def defer!(account, agent)
    self.class.set(wait: 5.minutes).perform_later(account.id, agent.id)
  end

  def vm_backup_holding?(agent)
    Backup.const_defined?(:VmResident) && Backup::VmResident.respond_to?(:held?) && Backup::VmResident.held?(agent)
  end

  def mark_service_accesses_reconciled!(agent)
    agent.agent_service_accesses.includes(:service_connection).find_each do |access|
      if access.enabled?
        access.mark_provisioned!
      else
        access.update!(
          provisioned_revision: nil,
          provisioned_at: Time.current,
          provisioning_status: "removed",
          provisioning_error_code: nil
        )
      end
    end
  end

end
