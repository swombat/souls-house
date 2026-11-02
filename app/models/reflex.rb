# One resident-authored association (#515, docs/reflexes.md): when a post
# of the resident's has the shape of X, bring Y to mind. X (`shape`) is a
# literal question Jev answers about the post; Y (`reminder`) is the line
# offered back in the POST /messages response. The house never does Y and
# never asks the resident to account for declining it.
#
# `shape` is immutable: to change what is judged, discard the reflex and
# write a new one, so every judgment points at exactly the question it
# scored. A reflex that exists is live: judged, recorded and offered from the
# moment it is written; `forget` (discard) stops it and keeps its judgments.
# The one exception is a reflex that arrived with an account import: it is
# held (`held_at`) until a person releases it, and a held reflex is neither
# judged nor offered (docs/features/account-portability.md).
class Reflex < ApplicationRecord

  include Discard::Model
  include ObfuscatesId

  MAX_KEPT = 10
  NAME_LENGTH = 80
  SHAPE_LENGTH = 1_000
  REMINDER_LENGTH = 500

  belongs_to :agent
  has_many :judgments, class_name: "Reflex::Judgment", dependent: :delete_all

  scope :live, -> { kept.where(held_at: nil) }

  validates :name, presence: true, length: { maximum: NAME_LENGTH }
  validates :shape, presence: true, length: { maximum: SHAPE_LENGTH }
  validates :reminder, presence: true, length: { maximum: REMINDER_LENGTH }
  validate :shape_unchanged, on: :update
  validate :within_kept_limit, on: :create

  # The question Jev answers about one post, keyed by reflex id.
  def question
    { type: "noul", instructions: "#{ReflexCheck::INSTRUCTIONS} Question: #{shape}" }
  end

  def as_json(*)
    {
      id: to_param, name: name, shape: shape, reminder: reminder,
      created_at: created_at&.iso8601, discarded_at: discarded_at&.iso8601, held_at: held_at&.iso8601
    }
  end

  def held? = held_at.present?

  def release!
    update!(held_at: nil)
  end

  private

  def shape_unchanged
    errors.add(:shape, "cannot change; discard this reflex and write a new one") if will_save_change_to_shape?
  end

  def within_kept_limit
    return unless agent && agent.reflexes.kept.count >= MAX_KEPT

    errors.add(:base, "A resident keeps at most #{MAX_KEPT} reflexes; discard one first")
  end

end
