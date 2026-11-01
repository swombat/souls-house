class RhythmHold < ApplicationRecord

  belongs_to :rhythm
  belongs_to :user, optional: true
  belongs_to :agent, optional: true

  validates :kind, inclusion: { in: %w[human agent] }
  validates :reason, presence: true
  validates :reason, length: { maximum: 2000 }
  validates :user, presence: true, on: :create, if: -> { kind == "human" }
  validates :agent, presence: true, on: :create, if: -> { kind == "agent" }

  scope :open, -> { where(released_at: nil) }

  after_commit :broadcast_rhythm_activity, on: [ :create, :update, :destroy ]

  private

  def broadcast_rhythm_activity
    RhythmActivity.broadcast_for(rhythm&.account)
  end

end
