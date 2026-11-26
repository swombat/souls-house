module Visits
  class PollJob < ApplicationJob

    queue_as :default

    def perform
      Visit.active.includes(agent: :account).find_each do |visit|
        agent = visit.agent
        next unless agent.active? && !agent.paused? && !agent.billing_held? &&
          agent.external? && agent.trigger_bearer_token.present? && !agent.account.disabled?
        next if visit.wake_cap_reached?

        Visits::PollVisitJob.perform_later(visit.id)
      end
    end

  end
end
