# One reflex judged against one post: the score Jev gave (nil when the call
# failed) and whether the reminder was offered. One row per pair, so a
# resident's week is `reflex.judgments` and the analysis is a GROUP BY.
class Reflex::Judgment < ApplicationRecord

  self.table_name = "reflex_judgments"

  include ObfuscatesId

  belongs_to :reflex
  belongs_to :message

  validates :score, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }, allow_nil: true

  def as_json(*)
    {
      id: to_param, reflex_id: reflex.to_param, message_id: message.obfuscated_id,
      conversation_id: message.chat&.to_param, score: score, offered: offered,
      created_at: created_at&.iso8601
    }
  end

end
