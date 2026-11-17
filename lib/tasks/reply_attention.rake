namespace :reply_attention do
  # One-off (Daniel, eBVPKw): dismiss, never delete, open inferred flags whose
  # person neither wrote in the conversation before the message nor is named
  # by it (InferredReplyRecipients). Direct @tags are left alone.
  # Dry run by default; APPLY=1 dismisses.
  desc "Dismiss open inferred reply flags that fail InferredReplyRecipients"
  task dismiss_ineligible_inferred: :environment do
    apply = ENV["APPLY"] == "1"
    rosters = {}
    checked = failing = 0
    by_user = Hash.new(0)
    scope = ReplyExpectation.state_open
      .where.not(classifier_version: ReplyExpectation::DIRECT_MENTION_VERSION)
    scope.includes(message: :chat).group_by(&:message).each do |message, expectations|
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
        next unless apply
        chat.with_lock do
          expectation.reload
          expectation.dismiss! if expectation.state_open?
        end
      end
    end
    puts "#{apply ? 'Dismissed' : 'Would dismiss'} #{failing} of #{checked} open inferred flags"
    by_user.sort_by { |_, n| -n }.each { |uid, n| puts "  user #{uid}: #{n}" }
  end
end
