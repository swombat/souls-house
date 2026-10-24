# The shadow path of ReflexCheck: judges a post off the request path while
# none of the resident's reflexes is live. Retries a failed classifier call
# a few times; when the retries run out, the judgments are recorded with no
# score, so the week shows the miss rather than hiding it.
class ReflexCheckJob < ApplicationJob

  ATTEMPTS = 3

  queue_as :default
  limits_concurrency to: 1, key: ->(message_id) { "reflex-check-#{message_id}" }

  retry_on UtilityInference::InvalidResponse, wait: :polynomially_longer, attempts: ATTEMPTS do |job, _error|
    job.record_failure(job.arguments.first)
  end
  discard_on UtilityInference::MissingCredentials, UtilityInference::InputTooLong do |job, _error|
    job.record_failure(job.arguments.first)
  end

  def perform(message_id)
    check = check_for(message_id)
    return unless check
    return if Reflex::Judgment.where(message_id: message_id, reflex_id: check.reflexes.map(&:id)).where.not(score: nil).count == check.reflexes.size

    # Off the post path there is no response to carry a cue: never offer.
    check.call(raise_errors: true, offer: false)
  end

  def record_failure(message_id)
    check_for(message_id)&.record_failure
  end

  private

  def check_for(message_id)
    message = Message.find_by(id: message_id)
    return unless ReflexCheck.checkable?(message)

    reflexes = message.agent.reflexes.kept.where("created_at <= ?", message.created_at).to_a
    ReflexCheck.new(message, reflexes) if reflexes.any?
  end

end
