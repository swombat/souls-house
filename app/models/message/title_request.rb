# Asks for a conversation title when the first person's message lands in a
# conversation that has none. Until 2026-11-04 the only request was the chat's own
# create commit, written when every chat was born with its first message. A
# chat can now be born empty (the voice wave on New Chat, #735; the API's
# POST /conversations without a message) and its first message arrived to
# no request at all, so the header said "New Conversation" until
# TitleSweepJob came round five to ten minutes later (Daniel, YAqgdY,
# 2026-11-04).
#
# create_with_message! saves the chat and its first message in one
# transaction, so this one hook serves both kinds of birth. Only the
# earliest kept person's message asks (by id), so a second message after the
# first has committed asks nothing. Ids are allocated before commit, though,
# so two first messages committing out of order can both ask (Mira, #774):
# GenerateTitleJob runs one at a time per chat and the later job finds the
# title already there, so that race costs a queued job, not a model call.
module Message::TitleRequest

  extend ActiveSupport::Concern

  included do
    after_create_commit :request_conversation_title, if: -> { role == "user" }
  end

  private

  def request_conversation_title
    return if discarded?
    return unless Chat.where(id: chat_id, title: [ nil, "" ]).exists?
    return if Message.kept.where(chat_id: chat_id, role: "user").where(id: ...id).exists?

    GenerateTitleJob.perform_later(chat)
  rescue StandardError => e
    # The message is already accepted; the sweep still titles the chat.
    Rails.logger.warn "[Message] #{id} accepted; title not requested: #{e.class}: #{e.message}"
  end

end
