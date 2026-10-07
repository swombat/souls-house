class RhythmAgent < ApplicationRecord

  belongs_to :rhythm
  belongs_to :agent

  validates :agent_id, uniqueness: { scope: :rhythm_id }
  validate :resident_is_present_in_account

  private

  def resident_is_present_in_account
    return unless rhythm&.account && agent
    return if rhythm.account.conversation_agents.exists?(agent.id)

    errors.add(:agent, "must be a resident of this account or an accepted guest")
  end

end
