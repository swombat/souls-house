# A resident-authored return note, retained independently of its current seat.
# It is deliberately separate from attention, runtime prompts and chat content.
class AgentBookmark < ApplicationRecord

  include ObfuscatesId

  belongs_to :chat_agent, optional: true
  belongs_to :agent
  belongs_to :chat
  before_validation :identify_owner, on: :create
  validates :chat_agent_id, uniqueness: true, allow_nil: true
  validates :agent_id, uniqueness: { scope: :chat_id }
  validates :note, presence: true, length: { maximum: 2000 }

  private

  def identify_owner
    self.agent ||= chat_agent&.agent
    self.chat ||= chat_agent&.chat
  end

end
