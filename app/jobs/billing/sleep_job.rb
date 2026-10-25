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

    def perform(agent_id, now: Time.current)
      agent = Agent.find_by(id: agent_id)
      entitlement = agent && ResidentEntitlement.find_by(agent: agent)
      return unless entitlement&.held?

      ResidentTurn.pending.where(agent: agent, state: "queued").find_each(&:cancel!)
      if busy?(agent) && entitlement.held_at && now < entitlement.held_at + ResidentEntitlement::DRAIN
        self.class.set(wait: RECHECK).perform_later(agent_id)
        return
      end

      stop!(agent)
    end

    private

    def busy?(agent)
      ResidentTurn.occupying_capacity.where(agent: agent).exists? ||
        agent.agent_runtime_interactions.where(finished_at: nil).exists?
    end

    def stop!(agent)
      return unless agent.externally_hosted?

      if Agents::RemoteRuntime.dispatchable?(agent)
        Agents::RemoteRuntime.stop!(agent)
      else
        Agents::Sandbox.new(agent).stop!
      end
    rescue StandardError => error
      Rails.error.report(error, handled: true, context: { subsystem: "billing", agent_id: agent.id })
    end

  end
end
