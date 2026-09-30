# Private human writing, deliberately not Broadcastable or part of a transcript.
class ConversationDraft < ApplicationRecord

  class Conflict < StandardError

    attr_reader :draft

    def initialize(draft)
      @draft = draft
      super("This draft changed on another client")
    end

  end

  belongs_to :chat
  belongs_to :user
  validates :content, length: { maximum: 100_000 }
  validates :content, exclusion: { in: [ nil ] }

  def self.for(chat:, user:)
    find_or_create_by!(chat: chat, user: user)
  end

  def replace!(content:, revision:)
    with_lock do
      check_revision!(revision)
      update!(content: content, revision: self.revision + 1)
    end
    self
  end

  # Keep an empty, revisioned row: deleting it would admit stale offline writes.
  # Message persistence and clearing are one transaction, including validation failure.
  def send_message!(message, revision:)
    with_lock do
      check_revision!(revision)
      # Multipart forms encode line breaks as CRLF; JSON autosaves preserve LF.
      # Compare text across that transport difference, then send the saved bytes.
      raise Conflict.new(self) unless normalized_line_endings(content) == normalized_line_endings(message.content.to_s)
      message.content = content

      if message.save
        update!(content: "", revision: self.revision + 1)
        true
      else
        false
      end
    end
  end

  def as_json(*)
    { content: content, revision: revision }
  end

  private

  def normalized_line_endings(text)
    text.gsub(/\r\n?/, "\n")
  end

  def check_revision!(expected)
    unless expected.to_s.match?(/\A\d+\z/) && expected.to_s.to_i == revision
      raise Conflict.new(self)
    end
  end

end
