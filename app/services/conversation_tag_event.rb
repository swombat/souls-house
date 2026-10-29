# The room's record that its tag changed: "Daniel changed the tag to Building."
# Platform-authored (role "system", no author), like ConversationModelEvent,
# so the transcript shows who changed the tag and when, for everyone in the
# room, with no setting to switch it on.
class ConversationTagEvent

  # Writes nothing when the tag did not actually change.
  def self.changed!(chat:, from:, to:, by:)
    return if from&.id == to&.id

    chat.messages.create!(role: "system", content: "#{actor_label(by)} #{describe(from, to)}.")
  end

  def self.describe(from, to)
    if to&.pinned?
      "pinned this conversation"
    elsif to.nil? && from&.pinned?
      "unpinned this conversation"
    elsif to.nil?
      "removed the tag #{from.label}"
    elsif from.nil?
      "tagged this conversation #{to.label}"
    else
      "changed the tag to #{to.label} (was #{from.label})"
    end
  end

  def self.actor_label(by)
    case by
    when Agent then by.name
    when User then ResidentFacingName.for(by)
    else "Someone"
    end
  end

end
