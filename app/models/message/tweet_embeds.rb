# Tweet cards under a message (JdwnWj): a message whose text links an x.com /
# twitter.com post gets a card for it once the post is fetched.
#
# The links are read whenever the message's text settles: on create, on an
# edit, and when a streamed reply stops streaming (its chunks are written
# with update_columns, so only the final save is seen here). A message still
# streaming is not read; its link may be half-written.
module Message::TweetEmbeds

  extend ActiveSupport::Concern

  included do
    has_many :message_tweet_embeds, -> { order(:position, :id) }, dependent: :delete_all
    has_many :tweet_embeds, through: :message_tweet_embeds

    after_save_commit :sync_tweet_embeds_later, if: :tweet_links_settled?
  end

  # Point this message at the shared rows for the posts its text links, and
  # drop links an edit removed. => the TweetEmbeds still waiting for a fetch.
  #
  # Runs under a lock on the message row and reads the message afresh there,
  # so two sync jobs for one message apply in turn and each reconciles the
  # text as it is now, not as it was when the job was queued; a message that
  # has started streaming again since is left alone (its own end will queue
  # another sync).
  #
  # When what the message shows changed (a cached card added, a card's link
  # removed), the open conversation is told after commit. A fetch can land
  # while this links (and announce before the link exists), so the linked
  # rows are read again once the links are committed.
  def sync_tweet_embeds!
    shown_changed = false
    linked = []
    outcome = with_lock do
      next :streaming if streaming?

      ids = discarded? ? [] : TweetEmbed.status_ids_in(content)
      embeds = ids.map { TweetEmbed.for_status_id!(it) }

      removed = message_tweet_embeds.unscope(:order).where.not(tweet_embed_id: embeds.map(&:id))
      shown_changed = true if removed.joins(:tweet_embed).where(tweet_embeds: { state: "fetched" }).exists?
      removed.delete_all
      embeds.each_with_index do |embed, position|
        link = message_tweet_embeds.find_or_initialize_by(tweet_embed_id: embed.id)
        next unless link.new_record? || link.position != position

        link.update!(position: position)
        linked << embed.id
      end
      embeds
    end
    message_tweet_embeds.reset
    return [] if outcome == :streaming

    states = TweetEmbed.where(id: outcome.map(&:id)).pluck(:id, :state).to_h
    shown_changed ||= linked.any? { states[it] == "fetched" }
    tweet_card_arrived! if shown_changed
    outcome.select { states[it.id] == "pending" }
  end

  def tweet_embeds_json
    message_tweet_embeds.filter_map { it.tweet_embed.card_json }
  end

  # What this message shows changed without its own save: take a revision
  # and write it in one transaction, so the app-sync announcement (made after
  # commit by Revisioned) never precedes the row it announces; then tell the
  # open web conversation, also after commit.
  def tweet_card_arrived!
    channel = "Chat:#{chat.obfuscated_id}"
    transaction do
      update_columns_with_revision(updated_at: Time.current)
      ActiveRecord.after_all_transactions_commit do
        ActionCable.server.broadcast(channel, { action: "refresh", prop: "messages" })
      end
    end
  end

  private

  def tweet_links_settled?
    return false unless role.in?(%w[user assistant])
    return false if streaming?

    saved_change_to_content? || saved_change_to_streaming? || saved_change_to_discarded_at? ||
      (previously_new_record? && content.present?)
  end

  def sync_tweet_embeds_later
    # Nothing linked before and nothing linked now: no job.
    return if !message_tweet_embeds.exists? && TweetEmbed.status_ids_in(content).empty?

    TweetEmbedSyncJob.perform_later(id)
  end

end
