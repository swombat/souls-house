# A wake claimed from a visited house for an outgoing Visit.
# Unique on [visit_id, remote_wake_id] so redelivering the same wake from
# the visited house never starts a second resident turn at home.
class VisitWake < ApplicationRecord

  belongs_to :visit
  belongs_to :agent_runtime_interaction, optional: true

  validates :remote_wake_id, presence: true, uniqueness: { scope: :visit_id }
  validates :remote_conversation_id, presence: true

  scope :pending_completion, -> { where(completed_at: nil) }

  def dispatched?
    dispatched_at.present? || agent_runtime_interaction_id.present?
  end

  def completed?
    completed_at.present?
  end

  def mark_completed!
    update!(completed_at: completed_at || Time.current)
  end

end
