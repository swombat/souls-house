# How the house names a human to a resident: by profile name, never by email.
# Residents are shown people the way the web shows them; a login identifier is
# not a name (Daniel, 24 Oct: "nobody wants to be addressed as their email").
#
# A person with no profile name is "Member <id>", not their email or its local
# part. When two different people in one conversation share a name, each label
# carries the person's id in brackets so attribution stays unambiguous.
module ResidentFacingName

  module_function

  def for(user)
    return if user.nil?

    user.full_name.to_s.squish.presence || "Member #{user.obfuscated_id}"
  end

  # Labels for a set of users, disambiguating only names that collide.
  # Returns { user_id => label }.
  def labels_for(users)
    users = users.compact.uniq(&:id)
    groups = users.group_by { |user| self.for(user) }
    users.to_h do |user|
      base = self.for(user)
      [ user.id, groups.fetch(base).size > 1 ? "#{base} [#{user.obfuscated_id}]" : base ]
    end
  end

  # Labels for every human who has written in a conversation.
  def labels_for_chat(chat)
    labels_for(User.where(id: chat.messages.kept.where(role: "user").where.not(user_id: nil).select(:user_id)).includes(:profile).to_a)
  end

end
