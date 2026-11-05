# Every five minutes: give a title to any conversation that has a user
# message, is more than five minutes old and still has none, so none stays
# untitled for much more than ten (Daniel, 2026-10-29). GenerateTitleJob runs once
# when the first person's message lands, on the account's own OpenRouter key and
# then on the house's (it spends one of this job's attempts when it does). It
# doesn't retry, and before 2026-11-04 it did nothing for accounts with no key
# and failed outright when that key couldn't reach the title model (seen
# 2026-10-28: a 404 for google/gemini-2.5-flash), so the chat stayed "New
# Conversation" for good.
#
# The sweep asks again on the house's key, on a model from a different family
# than the one that failed (TitleSweepJob.fallback_for). Each chat gets at
# most MAX_ATTEMPTS sweeps, so a chat no model can title costs three small
# calls, not one every few minutes forever. Without the house key nothing is
# asked and no attempt is spent. A run stops taking new chats after
# RUN_BUDGET, well inside both the next tick and the concurrency lease, and
# each attempt is reserved with a conditional update, so overlapping runs
# can't take a chat past the cap.
class TitleSweepJob < ApplicationJob

  queue_as :default
  limits_concurrency to: 1, key: "title-sweep", duration: 15.minutes
  discard_on UtilityInference::MissingCredentials

  GRACE = 5.minutes
  RUN_BUDGET = 3.minutes
  MAX_ATTEMPTS = 3
  BATCH = 50

  HAIKU = { model: "anthropic/claude-haiku-5.5", provider: "anthropic" }.freeze
  OPENAI = { model: "openai/gpt-5.4-mini", provider: "openai" }.freeze

  # Daniel, 2026-10-29: OpenAI failed → Anthropic, Anthropic failed → OpenAI,
  # anything else → Haiku.
  def self.fallback_for(model)
    case model.to_s
    when %r{\Aopenai/} then HAIKU
    when %r{\Aanthropic/} then OPENAI
    else HAIKU
    end
  end

  def self.candidates
    Chat.kept
        .where(title: [ nil, "" ])
        .where(title_sweep_attempts: ...MAX_ATTEMPTS)
        .where(created_at: ...GRACE.ago)
        .where(id: Message.kept.where(role: "user").select(:chat_id))
        .order(created_at: :desc)
        .limit(BATCH)
  end

  def perform
    key = HouseInference::Offering.key
    return if key.blank? || key.start_with?("<")

    fallback = self.class.fallback_for(UtilityInference::TITLE_MODEL)
    deadline = Time.current + RUN_BUDGET
    self.class.candidates.each do |chat|
      break if Time.current >= deadline
      # Reserved before the call, so a crash mid-call still uses the attempt.
      next unless reserve_attempt(chat)

      title = GenerateTitlePrompt.new(chat: chat, model: fallback[:model], provider: fallback[:provider]).generate_title
      chat.update!(title: title) if title.present? && chat.reload.title.blank?
    rescue UtilityInference::InvalidResponse, UtilityInference::InputTooLong => error
      Rails.logger.warn("[TitleSweepJob] chat #{chat.id} not titled (#{error.class})")
    end
  end

  # Shared with GenerateTitleJob, whose house-key call spends an attempt too.
  def self.reserve_attempt(chat)
    attempts = chat.title_sweep_attempts
    return false if attempts >= MAX_ATTEMPTS

    Chat.where(id: chat.id, title_sweep_attempts: attempts)
        .update_all(title_sweep_attempts: attempts + 1) == 1
  end

  private

  def reserve_attempt(chat) = self.class.reserve_attempt(chat)

end
