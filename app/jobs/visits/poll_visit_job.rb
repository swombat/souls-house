module Visits
  class PollVisitJob < ApplicationJob

    queue_as :default
    limits_concurrency(
      to: 1,
      key: ->(visit_id) { "visit-poll-#{visit_id}" },
      duration: 2.minutes
    )

    def perform(visit_id)
      visit = Visit.includes(agent: :account).find_by(id: visit_id)
      return unless visit&.active?

      Visits::Poller.new(visit).call
    end

  end
end
