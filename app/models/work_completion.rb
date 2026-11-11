class WorkCompletion < ApplicationRecord

  include ObfuscatesId

  belongs_to :chat
  belongs_to :message
  belongs_to :agent, optional: true
  belongs_to :user, optional: true
  belongs_to :accepted_by, class_name: "User", optional: true

  FIELDS = %w[changes_summary result checks remaining].freeze
  validates(*FIELDS, presence: true, length: { maximum: 10_000 })
  validates :request_key, presence: true, length: { maximum: 100 },
    uniqueness: { scope: :chat_id }
  validate :immutable_submission, on: :update

  def as_work_json
    {
      id: to_param, message_id: message.to_param,
      source_revision: source_revision, review_revision: review_revision,
      changes_summary: changes_summary, result: result, checks: checks, remaining: remaining,
      accepted_at: accepted_at&.iso8601(6), accepted_revision: accepted_revision,
      closed_at: closed_at&.iso8601(6), closure_blocked: closure_blocked,
      current: chat.work_status_revision == (accepted_revision || review_revision)
    }
  end

  private

  def immutable_submission
    if (FIELDS + %w[chat_id message_id agent_id user_id request_key source_revision review_revision]).any? { |field| will_save_change_to_attribute?(field) }
      errors.add(:base, "A saved handoff cannot be edited; submit a new handoff")
    end
  end

end
