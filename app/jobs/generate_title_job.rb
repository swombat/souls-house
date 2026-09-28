class GenerateTitleJob < ApplicationJob

  def perform(chat)
    return if chat.title.present?

    return unless chat.messages.kept.where(role: "user").exists?

    title = GenerateTitlePrompt.new(chat: chat).generate_title
    chat.update!(title: title) if title.present?
  end

end
