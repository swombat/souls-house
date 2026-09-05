class ToolCall < ApplicationRecord

  belongs_to :message
  has_one :result, class_name: "Message", foreign_key: :tool_call_id, dependent: :nullify

  def thought_signature
    replay_payload&.dig("thought_signature")
  end

end
