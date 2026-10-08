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

  def self.actor_label(by)
    case by
    when Agent then "#{by.name} (the resident)"
    when User then by.full_name.presence || by.email_address
    else by.to_s
    end
  end

end
