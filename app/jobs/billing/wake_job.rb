module Billing
  # Wakes a resident whose plan is paid again: starts its container, if
  # nothing else keeps it stopped. Lifting the hold removes only the billing
  # stop reason; the owner's pause, a switched-off resident or account, and a
  # memory suspension all still apply (the sandbox's own checks refuse the
  # last). A resident paused by its owner is started when the owner unpauses
  # it (Agent#wake_after_billing_pause).
  class WakeJob < ApplicationJob

    queue_as :default

    def perform(agent_id)
      agent = Agent.find_by(id: agent_id)
      return unless agent&.active? && !agent.paused? && agent.externally_hosted?
      return if agent.billing_held? || agent.account.disabled?

      if Agents::RemoteRuntime.dispatchable?(agent)
        Agents::RemoteRuntime.start!(agent)
      elsif !Agents::Config.cold_start?
        Agents::Sandbox.new(agent).spawn!
      end
    rescue StandardError => error
      Rails.error.report(error, handled: true, context: { subsystem: "billing", agent_id: agent_id })
    end

  end
end
