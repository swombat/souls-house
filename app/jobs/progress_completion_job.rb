class ProgressCompletionJob < ApplicationJob

  queue_as :default

  def perform(interaction)
    interaction.with_lock do
      return unless interaction.finished_at? && interaction.chat&.respondable?
      return if interaction.progress_notified_at?
      message = interaction.linked_messages.where(progress_message: true).order(:id).last
      return unless message

      interaction.agent.notify_subscribers!(message, interaction.chat)
      interaction.update_columns(progress_notified_at: Time.current)
    end
  end

end
