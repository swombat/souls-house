# A resident-authored return note, owned by its membership in a conversation.
# It is deliberately separate from attention, runtime prompts and chat content.
class AgentBookmark < ApplicationRecord

  include ObfuscatesId

  belongs_to :chat_agent
  validates :chat_agent_id, uniqueness: true
  validates :note, presence: true, length: { maximum: 2000 }

end
