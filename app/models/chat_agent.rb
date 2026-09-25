class ChatAgent < ApplicationRecord

  SUMMARY_COOLDOWN = 5.minutes

  belongs_to :chat
  belongs_to :agent
  has_one :agent_bookmark, dependent: :destroy

  validates :agent_id, uniqueness: { scope: :chat_id }

  scope :closed_for_initiation, -> { where.not(closed_for_initiation_at: nil) }
  scope :open_for_initiation, -> { where(closed_for_initiation_at: nil) }

  def closed_for_initiation? = closed_for_initiation_at?

  def close_for_initiation!
    update!(closed_for_initiation_at: Time.current)
  end

  def reopen_for_initiation!
    update!(closed_for_initiation_at: nil)
  end

  def summary_stale?
    agent_summary_generated_at.nil? || agent_summary_generated_at < SUMMARY_COOLDOWN.ago
  end

  def clear_borrowed_context!
    update_columns(borrowed_context_json: nil) if borrowed_context_json.present?
  end

end
