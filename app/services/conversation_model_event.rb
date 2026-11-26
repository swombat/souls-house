# The room's record that a resident's model changed, or cannot be used. These
# are platform-authored lines (role "system", no author), so nobody mistakes
# them for something the resident said, and the transcript shows who changed
# what and when without any separate bookkeeping column.
class ConversationModelEvent

  def self.changed!(seat:, from_model_id:, to_model_id:, by:)
    agent = seat.agent
    describe = ->(id) { id ? Agent.label_for_model(id) : "its default, #{agent.model_label}," }
    seat.chat.messages.create!(
      role: "system",
      content: "#{agent.name} will run on #{describe.(to_model_id)} in this conversation from its next turn, " \
        "instead of #{describe.(from_model_id).delete_suffix(',')}. Changed by #{actor_label(by)}."
    )
  end

  def self.unavailable!(chat:, agent:, selection:)
    chat.messages.create!(
      role: "system",
      content: "#{agent.name} did not respond: the model selected for this conversation, " \
        "#{selection.label}, #{selection.problem}. Choose another model from #{agent.name}'s button, " \
        "or \"Use resident default\" (#{agent.model_label})."
    )
  end

  # Agents::ModelSuccession moved a pin that had left the resident's list to
  # its successor. Written in the same transaction as the move, so the line
  # exists exactly when the move does.
  def self.moved_forward!(seat:, from_model_id:, to_model_id:, rhythm: nil)
    agent = seat.agent
    from = Agent.label_for_model(from_model_id)
    to = Agent.label_for_model(to_model_id)
    content = "#{agent.name}'s model in this conversation moved from #{from} to #{to}, " \
      "because #{from} is no longer on #{agent.name}'s list of models for conversations."
    content += " The rhythm \"#{rhythm.title}\" will use #{to} from now on too." if rhythm
    content += " Choose another from #{agent.name}'s button to change it."
    seat.chat.messages.create!(role: "system", content: content)
  end

  def self.actor_label(by)
    case by
    when Agent then "#{by.name} (the resident)"
    when User then by.full_name.presence || by.email_address
    else by.to_s
    end
  end

end
