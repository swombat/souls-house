# Tells the account's owner when a resident starts spending on its paid
# fallback (#690 slice C): the first paid call in each cap period, and again
# after the owner turns the fallback off and on. "Paid call" means one that
# reached the provider (settled, or unresolved with its reservation held),
# not a hop that was opened and then refused before anything was sent.
#
# The claim (policy.use_notice_at) and the enqueue commit together: if the
# enqueue raises, the claim rolls back and the next paid call tries again.
# The conditional update makes it once even when two calls finish at once.
module ResidentFallback
  module UseNotice

    module_function

    def after_paid_call(call)
      turn = call.resident_fallback_turn
      policy = call.agent&.fallback_policy
      return unless turn && policy

      period_start = policy.period_start(call.admitted_at || Time.current)
      ResidentFallbackPolicy.transaction(requires_new: true) do
        claimed = ResidentFallbackPolicy.where(id: policy.id)
          .where("use_notice_at IS NULL OR use_notice_at < ?", period_start)
          .update_all(use_notice_at: Time.current)
        ResidentFallbackMailer.first_use(turn).deliver_later if claimed == 1
      end
    rescue StandardError => e
      Rails.logger.warn("[ResidentFallback::UseNotice] not sent for #{call.agent_id}: #{e.class}")
    end

  end
end
