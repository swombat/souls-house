module Billing
  # Puts a resident whose plan lapsed to sleep (docs/proposals/2026-10-07-stripe-billing.md,
  # "The hold boundary"). New work is already refused everywhere it starts;
  # this cancels what is queued, lets a turn already running finish (up to
  # ResidentEntitlement::DRAIN after the hold), then stops the container.
  # Stopped, never removed: home, memory and backups stay as they are, and
  # paying starts it again (Billing::WakeJob).
  class SleepJob < ApplicationJob

    queue_as :default

    RECHECK = 2.minutes
    # A stop that failed is tried again for as long as the resident sleeps:
    # nothing else would (the reconciler leaves asleep residents alone).
    STOP_RETRY = 5.minutes

    class StopFailed < StandardError; end

    def perform(agent_id, now: Time.current, attempt: 0)
      agent = Agent.find_by(id: agent_id)
      entitlement = agent && ResidentEntitlement.find_by(agent: agent)
      return unless entitlement&.held?

      ResidentTurn.pending.where(agent: agent, state: "queued").find_each(&:cancel!)
      if busy?(agent) && entitlement.held_at && now < entitlement.held_at + ResidentEntitlement::DRAIN
        self.class.set(wait: RECHECK).perform_later(agent_id)
        return
      end

      stop!(agent, attempt)
    end

    private

    def busy?(agent)
      ResidentTurn.occupying_capacity.where(agent: agent).exists? ||
        agent.agent_runtime_interactions.where(finished_at: nil).exists?
    end

    # Returns true once the container is stopped (or the VM runner has the
    # stop command). Otherwise reports and keeps custody: tries again later.
    def stop!(agent, attempt)
      return true unless agent.externally_hosted?

      if Agents::RemoteRuntime.dispatchable?(agent)
        Agents::RemoteRuntime.stop!(agent)
      else
        sandbox = Agents::Sandbox.new(agent)
        unless sandbox.stop! || sandbox.confirmed_stopped?
          raise StopFailed, "docker stop failed for #{agent.container_name} and it isn't confirmed stopped"
        end
      end
      true
    rescue StandardError => error
      Rails.error.report(error, handled: true,
        context: { subsystem: "billing", agent_id: agent.id, attempt: attempt })
      self.class.set(wait: STOP_RETRY).perform_later(agent.id, attempt: attempt + 1)
      false
    end

  end
end
