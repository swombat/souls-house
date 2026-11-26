module Visits
  # Marks a claimed visit wake complete on the visited house when the home
  # resident's turn finishes, if the resident didn't already complete it.
  class CompleteWakeJob < ApplicationJob

    queue_as :default

    def perform(interaction_id)
      wake = VisitWake.includes(:visit, :agent_runtime_interaction)
        .find_by(agent_runtime_interaction_id: interaction_id)
      return unless wake && !wake.completed?
      return unless wake.visit.active?

      response = Visits::Client.new.complete_wake(
        wake.visit,
        wake_id: wake.remote_wake_id,
        status: wake.agent_runtime_interaction&.runtime_status
      )
      wake.mark_completed! if response.success? || response.status == 404
    rescue Visits::Client::Error => e
      Rails.logger.warn "[Visits::CompleteWakeJob] wake #{wake&.id} completion failed: #{e.class}: #{e.message}"
    end

  end
end
