# One verdict of the stalled-thread sweeper on a quiet room, for the room's
# state at that moment (its last message). See StalledThreadSweeper and,
# for what a verdict may do, StalledThreadWake.
class StalledThreadSweep < ApplicationRecord

  OUTCOMES = %w[would_wake person_holds quiet error].freeze

  belongs_to :account
  belongs_to :chat
  belongs_to :message
  has_many :agent_runtime_interactions, dependent: :nullify

  validates :outcome, inclusion: { in: OUTCOMES }

  # What a woken run is told. Grants nothing; points at the room.
  def nudge_text
    <<~TEXT.strip
      STALLED-THREAD CHECK (platform, not a person). Conversation #{chat.to_param} has been quiet for #{quiet_minutes} minutes since its last message (#{message.obfuscated_id}). A check of the room judged that you may have a step to take that is already authorised: something you said you would do, a review or request addressed to you, or approved work to merge.

      First read the room and check whether that is so. If there is nothing for you to do, or the next move is a person's, say nothing, or one line if it helps. If there is, take it now within the authorisation you already had, or say plainly what is blocking it. This wake grants no new permissions, and the check will not wake you again in this room until a person posts.
    TEXT
  end

end
