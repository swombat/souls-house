class ModerateMessageJob < ApplicationJob

  queue_as :default

  retry_on Faraday::TimeoutError, Faraday::ConnectionFailed,
           Faraday::TooManyRequestsError, Faraday::ServerError,
           wait: :polynomially_longer, attempts: 3
  discard_on ActiveRecord::RecordNotFound

  def perform(message)
    return unless message.content.present? && message.moderated_at.nil?

    scores = UtilityInference.moderate(message.content)
    message.update_columns(moderation_scores: scores, moderated_at: Time.current)
  end

end
