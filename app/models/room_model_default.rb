# The model a resident starts on in new conversations in one room of an
# account (room nil is Main). It seeds the conversation seat when the resident
# joins (ChatAgent#model_id), so the room's model button shows it and anyone
# may change it there afterwards. Changing a room's default never touches
# conversations that already exist, and a conversation moved into the room
# keeps the model it had.
#
# Only a model on the resident's list for conversations can be a room default;
# the resident's own default model means "no room default" and is not stored.
# A default that later stops being valid (the list changed) is skipped when a
# seat is created, and reported on the Rooms page.
class RoomModelDefault < ApplicationRecord

  belongs_to :account
  belongs_to :room, optional: true
  belongs_to :agent

  validates :model_id, presence: true
  validates :agent_id, uniqueness: { scope: %i[account_id room_id] }
  validate :room_belongs_to_account
  validate :agent_is_a_resident_of_account
  validate :model_is_selectable

  # The room's model for this resident, when there is one it can still use.
  def self.model_for(account_id:, room_id:, agent:)
    default = find_by(account_id: account_id, room_id: room_id, agent_id: agent.id)
    default.model_id if default && default.problem.nil?
  end

  # Set the room default, or clear it with nil, "default" or the resident's
  # own default model. Returns the record, or nil when cleared.
  def self.set!(account:, room:, agent:, model_id:)
    model_id = model_id.to_s.strip
    existing = find_by(account: account, room: room, agent: agent)
    if model_id.blank? || model_id == "default" || model_id == agent.model_id
      existing&.destroy!
      return nil
    end

    record = existing || new(account: account, room: room, agent: agent)
    record.update!(model_id: model_id)
    record
  end

  def problem
    agent.model_selection_problem(model_id)
  end

  def as_json(_options = nil)
    {
      "room_id" => room&.to_param || "main",
      "agent_id" => agent.to_param,
      "model_id" => model_id,
      "label" => Agent.label_for_model(model_id),
      "problem" => (problem && "#{Agent.label_for_model(model_id)} #{problem}")
    }
  end

  private

  def room_belongs_to_account
    errors.add(:room, "must belong to this account") if room && room.account_id != account_id
  end

  def agent_is_a_resident_of_account
    errors.add(:agent, "must be a resident of this account") if agent && agent.account_id != account_id
  end

  def model_is_selectable
    return unless agent && model_id.present? && will_save_change_to_model_id?

    if (issue = agent.model_selection_problem(model_id))
      errors.add(:model_id, "#{Agent.label_for_model(model_id)} #{issue}")
    end
  end

end
