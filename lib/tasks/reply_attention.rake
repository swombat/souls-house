namespace :reply_attention do
  # One-off (Daniel, eBVPKw): dismiss, never delete, open inferred flags whose
  # person neither wrote in the conversation before the message nor is named
  # by it (InferredReplyRecipients). Direct @tags are left alone.
  # Dry run by default; APPLY=1 dismisses.
  #
  # With APPLY=1 each message is decided inside its chat's lock: the message
  # and its open inferred flags are re-read there, so an edit or a
  # reclassification that lands first (e.g. turning the flag into a direct
  # @tag) is what gets judged, never a row selected before the lock.
  desc "Dismiss open inferred reply flags that fail InferredReplyRecipients"
  task dismiss_ineligible_inferred: :environment do
    apply = ENV["APPLY"] == "1"
    open_inferred = -> { ReplyExpectation.state_open.where.not(classifier_version: ReplyExpectation::DIRECT_MENTION_VERSION) }
    rosters = {}
    checked = failing = 0
    by_user = Hash.new(0)

    judge = lambda do |message_id|
      message = Message.find_by(id: message_id)
      return unless message
      expectations = open_inferred.call.where(message_id: message.id).to_a
      return if expectations.empty?
      chat = message.chat
      users = rosters[chat.account_id] ||= chat.account.users.joins(:memberships)
        .where(memberships: { account_id: chat.account_id }).merge(Membership.confirmed)
        .distinct.includes(:profile).to_a
      keep = InferredReplyRecipients.call(message: message, user_ids: expectations.map(&:user_id), users: users)
      expectations.each do |expectation|
        checked += 1
        next if keep.include?(expectation.user_id)
        failing += 1
        by_user[expectation.user_id] += 1
        expectation.dismiss! if apply
      end
    end

    open_inferred.call.distinct.pluck(:message_id).each do |message_id|
      if apply
        chat = Message.find_by(id: message_id)&.chat
        chat&.with_lock { judge.call(message_id) }
      else
        judge.call(message_id)
      end
    end

    puts "#{apply ? 'Dismissed' : 'Would dismiss'} #{failing} of #{checked} open inferred flags"
    by_user.sort_by { |_, n| -n }.each { |uid, n| puts "  user #{uid}: #{n}" }
  end
end
