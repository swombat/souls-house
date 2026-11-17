# Who a classifier-inferred reply flag may go to (Daniel, eBVPKw, after
# JNwnqB gave Pepe's "you" to Daniel in Mexzungu). A person qualifies only if
#   1. they have already written in that conversation, before the message, or
#   2. the message names them: first or last name, as a whole word, any case.
# There is no owner fallback. A last name counts only when no other confirmed
# member of the account shares it: in a family account everyone is a Tenner,
# and "Lume Tenner" must not reach Daniel.
#
# Direct @tags (DirectReplyMentions) never pass through here.
class InferredReplyRecipients

  def self.call(message:, user_ids:, users:)
    new(message: message, users: users).eligible(user_ids)
  end

  def initialize(message:, users:)
    @message = message
    @users = users
  end

  def eligible(user_ids)
    return [] if user_ids.empty?
    writers = @message.chat.messages.kept.where(role: "user", user_id: user_ids)
      .where("messages.id < ?", @message.id).reorder(nil).distinct.pluck(:user_id)
    user_ids.select do |id|
      next true if writers.include?(id)
      user = @users.find { |u| u.id == id }
      user && named?(user)
    end
  end

  def named?(user)
    names = [ user.first_name ]
    names << user.last_name if unique_last_name?(user)
    names.compact_blank.any? { |name| whole_word?(name) }
  end

  private

  def unique_last_name?(user)
    last = user.last_name.to_s.strip.downcase
    return false if last.empty?
    @users.none? { |other| other.id != user.id && other.last_name.to_s.strip.downcase == last }
  end

  def whole_word?(name)
    @message.content.to_s.match?(/(?<![\p{L}\p{N}_])#{Regexp.escape(name.strip)}(?![\p{L}\p{N}_])/i)
  end

end
