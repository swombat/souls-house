# The one path by which a message takes a sync revision (issue #94, PR B).
# Every save that changes what a client can see bumps the chat's counter with
# UPDATE … RETURNING inside the write's own transaction, so concurrent writers
# in one chat serialise on the chat row and commit revisions in order. Being a
# model callback, it covers web, app, agent API and resident replies alike.
# Streaming chunks use update_columns and skip it; the final save bumps.
module Message::Revisioned

  extend ActiveSupport::Concern

  # Attributes that never change what a client renders.
  UNSYNCED_ATTRIBUTES = %w[
    revision updated_at moderation_scores moderated_at replay_payload
    input_tokens output_tokens cached_tokens cache_creation_tokens thinking_tokens
    envelope_prompt_bytes stable_prompt_bytes stable_prompt_sha256 transcript_prompt_bytes
    prompt_layout_version
  ].freeze

  included do
    before_save :take_next_revision, if: :sync_visible_change?
  end

  # For the rare callback that must write another message without running its
  # callbacks: the change is still client-visible, so it still takes a revision.
  def update_columns_with_revision(attributes)
    update_columns(attributes.merge(revision: take_next_revision))
  end

  private

  def sync_visible_change?
    new_record? || (changed - UNSYNCED_ATTRIBUTES).any?
  end

  def take_next_revision
    self.revision = Chat.connection.select_value(
      Chat.sanitize_sql([ "UPDATE chats SET message_revision = message_revision + 1 WHERE id = ? RETURNING message_revision", chat_id ])
    )
  end

end
