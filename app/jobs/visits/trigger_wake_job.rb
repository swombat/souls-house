module Visits
  class TriggerWakeJob < ApplicationJob

    class SessionBusy < StandardError; end

    queue_as :default
    limits_concurrency(
      to: 1,
      key: ->(visit_wake_id) {
        wake = VisitWake.find_by(id: visit_wake_id)
        wake ? "visit-conv-#{wake.visit_id}-#{wake.remote_conversation_id}" : "visit-wake-#{visit_wake_id}"
      },
      duration: 35.minutes
    )
    retry_on SessionBusy, wait: 30.seconds, attempts: 20

    def perform(visit_wake_id)
      visit_wake = VisitWake.includes(visit: { agent: :account }).find_by(id: visit_wake_id)
      return unless visit_wake
      return if visit_wake.dispatched?

      visit = visit_wake.visit
      agent = visit.agent
      return unless visit.active?
      return unless agent.active? && !agent.paused? && !agent.billing_held? &&
        agent.external? && agent.trigger_bearer_token.present? && !agent.account.disabled?

      result = ExternalAgentVisitRequest.new(visit_wake: visit_wake).call
      raise SessionBusy, "Visit conversation session is busy" if result[:status] == 409 && !result[:skipped]
    end

  end
end
