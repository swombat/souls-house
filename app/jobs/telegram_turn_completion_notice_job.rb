class TelegramTurnCompletionNoticeJob < ApplicationJob

  queue_as :default

  def perform(interaction_id)
    run = AgentRuntimeInteraction.find_by(id: interaction_id, trigger_kind: "telegram")
    return unless run&.conversation_obfuscated_id.present?

    subscription = run.agent.telegram_threads.active.direct.find_by_obfuscated_id(run.conversation_obfuscated_id)
    TelegramTurnCompletionNotice.call(run, subscription) if subscription
  end

end
