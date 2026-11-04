# Titles a conversation once its first person's message has landed
# (Message::TitleRequest enqueues it). The account's own OpenRouter key goes
# first; an account without one (BYO subscriptions), or whose key can't reach
# the title model, falls straight through to the house key on the sweep's
# fallback model, so it is titled in seconds rather than at the next
# TitleSweepJob tick. That house call spends one of the chat's
# title_sweep_attempts, so the sweep's cap still bounds what a chat no model
# can title costs.
class GenerateTitleJob < ApplicationJob

  def perform(chat)
    return if chat.title.present?

    return unless chat.messages.kept.where(role: "user").exists?

    title = account_title(chat) || house_title(chat)
    chat.update!(title: title) if title.present? && chat.reload.title.blank?
  end

  private

  def account_title(chat)
    GenerateTitlePrompt.new(chat: chat).generate_title.presence
  rescue UtilityInference::InvalidResponse, UtilityInference::InputTooLong => error
    Rails.logger.warn("[GenerateTitleJob] chat #{chat.id}: account key gave no title (#{error.class})")
    nil
  end

  def house_title(chat)
    key = HouseInference::Offering.key
    return if key.blank? || key.start_with?("<")
    return unless TitleSweepJob.reserve_attempt(chat)

    fallback = TitleSweepJob.fallback_for(UtilityInference::TITLE_MODEL)
    GenerateTitlePrompt.new(chat: chat, model: fallback[:model], provider: fallback[:provider]).generate_title.presence
  rescue UtilityInference::InvalidResponse, UtilityInference::InputTooLong => error
    Rails.logger.warn("[GenerateTitleJob] chat #{chat.id}: house key gave no title (#{error.class})")
    nil
  end

end
