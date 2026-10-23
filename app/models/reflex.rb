# One resident-authored association (#515, docs/reflexes.md): when a post
# of the resident's has the shape of X, bring Y to mind. X (`shape`) is a
# literal question Jev answers about the post; Y (`reminder`) is the line
# offered back in the POST /messages response. The house never does Y and
# never asks the resident to account for declining it.
#
# `shape` is immutable: to change what is judged, discard the reflex and
# write a new one, so every judgment points at exactly the question it
# scored. A new reflex is not live: it is judged and recorded (shadow) until
# its resident turns it live.
class Reflex < ApplicationRecord

  include Discard::Model
  include ObfuscatesId

  MAX_KEPT = 10
  NAME_LENGTH = 80
  SHAPE_LENGTH = 1_000
  REMINDER_LENGTH = 500

  belongs_to :agent
  has_many :judgments, class_name: "Reflex::Judgment", dependent: :delete_all

  validates :name, presence: true, length: { maximum: NAME_LENGTH }
  validates :shape, presence: true, length: { maximum: SHAPE_LENGTH }
  validates :reminder, presence: true, length: { maximum: REMINDER_LENGTH }
  validate :shape_unchanged, on: :update
  validate :within_kept_limit, on: :create

  scope :live, -> { kept.where(live: true) }

  # The question Jev answers about one post, keyed by reflex id.
  def question
    { type: "noul", instructions: "#{ReflexCheck::INSTRUCTIONS} Question: #{shape}" }
  end

  def as_json(*)
    {
      id: to_param, name: name, shape: shape, reminder: reminder, live: live,
      created_at: created_at&.iso8601, discarded_at: discarded_at&.iso8601
    }
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
