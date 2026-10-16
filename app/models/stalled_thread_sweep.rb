# One verdict of the stalled-thread sweeper on a quiet room, for the room's
# state at that moment (its last message). Shadow mode only records: nothing
# is posted and nobody is woken. See StalledThreadSweeper.
class StalledThreadSweep < ApplicationRecord

  OUTCOMES = %w[would_wake person_holds quiet error].freeze

  belongs_to :account
  belongs_to :chat
  belongs_to :message

  validates :outcome, inclusion: { in: OUTCOMES }

end
