class RhythmAgent < ApplicationRecord

  belongs_to :rhythm
  belongs_to :agent

  before_validation :normalize_model_id
  validates :agent_id, uniqueness: { scope: :rhythm_id }
  validate :resident_is_present_in_account
  validate :model_is_selectable, if: -> { model_id.present? && will_save_change_to_model_id? }

  # The model this resident runs on in the rhythm's conversations: the
  # selected one, or the resident's default.
  def effective_model_id
    model_id.presence || agent&.model_id
  end

  private

  def normalize_model_id
    value = model_id.to_s.strip
    self.model_id = value.blank? || value == "default" ? nil : value
  end

  # Checked against the resident's allowlist when it is saved. At occurrence
  # time the seat is resolved by Agents::ModelSelection, which reports a
  # selection that has since stopped being valid rather than replacing it.
  def model_is_selectable
    return unless agent
    return unless (problem = agent.model_selection_problem(model_id))

    errors.add(:model_id, "#{Agent.label_for_model(model_id)} #{problem}")
  end

  def resident_is_present_in_account
    return unless rhythm&.account && agent
    return if rhythm.account.conversation_agents.exists?(agent.id)

    errors.add(:agent, "must be a resident of this account or an accepted guest")
  end

end
