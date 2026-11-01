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
  # When what the message shows changed here (a cached card added, a link
  # removed), the open conversation is told now; a pending card is told when
  # its fetch lands.
  def sync_tweet_embeds!
    ids = discarded? ? [] : TweetEmbed.status_ids_in(content)
    embeds = ids.map { TweetEmbed.for_status_id!(it) }
    shown_changed = false

    transaction do
      removed = message_tweet_embeds.where.not(tweet_embed_id: embeds.map(&:id))
      shown_changed = true if removed.joins(:tweet_embed).where(tweet_embeds: { state: "fetched" }).exists?
      removed.delete_all
      embeds.each_with_index do |embed, position|
        link = message_tweet_embeds.find_or_initialize_by(tweet_embed_id: embed.id)
        next unless link.new_record? || link.position != position

        link.update!(position: position)
        shown_changed = true if embed.state == "fetched"
      rescue ActiveRecord::RecordNotUnique
        nil
      end
    end
    message_tweet_embeds.reset
    tweet_card_arrived! if shown_changed
    embeds.select { it.state == "pending" }
  end

  def tweet_embeds_json
    message_tweet_embeds.filter_map { it.tweet_embed.card_json }
  end

  # A card finished arriving: the open conversation reloads its messages
  # (Chat broadcast) and app clients see a new revision.
  def tweet_card_arrived!
    update_columns_with_revision(updated_at: Time.current)
    ActionCable.server.broadcast("Chat:#{chat.obfuscated_id}", { action: "refresh", prop: "messages" })
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
