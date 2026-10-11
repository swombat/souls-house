# One collection run for one tweet stream (FieldTweetSource).
#
# The contract (agreed with Mira in nedPLe, 2026-10-11):
# - A window is frozen when it opens: until = now - LAG (so the run doesn't
#   race the provider's indexing), since = checkpoint - OVERLAP (for posts
#   indexed late), never before the connection.
# - Pages are fetched with the provider's own cursor. Each page is processed
#   in one transaction with the cursor that follows it, so a crash anywhere
#   either keeps the page and its cursor or neither.
# - The checkpoint moves to the window's end only when its last page has
#   been processed. A failure never moves it.
# - New tweets go to the backlog first and are imported from there, oldest
#   first, within the day's allowance. When the allowance is used up (or
#   the backlog still holds tweets) no new page is fetched: the open window
#   keeps its cursor and waits, so nothing is paid for twice and nothing is
#   paid for that couldn't be imported today.
# - A page that says there is more but gives no usable cursor isn't the end
#   of the window: the window stays open and the run counts as a failure.
# - Returned tweets that can't be read (no id, author or time) are counted
#   apart from duplicates, and the window they came in is kept as a gap.
# - Tweets already in the account (overlap, retries, discarded ones) are
#   counted, not imported again.
# - One run per source at a time (sync_claimed_at).
module FieldTweets
  class Sync

    LAG = 60.seconds
    OVERLAP = 10.minutes
    MIN_WINDOW = 1.minute
    MAX_PAGES_PER_RUN = 10
    # 1,000 tweets in one window: more than any one person posts in a poll
    # interval. Past it the rest of the window is recorded as a gap.
    MAX_WINDOW_PAGES = 50
    CLAIM_TTL = 10.minutes
    MAX_FAILURES = 8
    MAX_BACKOFF = 6.hours

    # The provider said there was more but gave nothing to ask for it with.
    class BrokenPage < StandardError

      def initialize = super("TwitterAPI.io said there were more results but gave no usable cursor; the window stays open")
      def status = nil
      def funding? = false
      def transient? = true

    end

    def self.due(now: Time.current)
      FieldTweetSource.where(state: "active").where("next_attempt_at IS NULL OR next_attempt_at <= ?", now)
    end

    # client: ->(api_key) { an object with #search(query, cursor:) }
    def initialize(source, client: ->(key) { TwitterApiIo.new(key) }, clock: -> { Time.current })
      @source = source
      @client_factory = client
      @clock = clock
    end

    # => :claimed (another run has it), :done, :more (window still open),
    # :waiting (allowance or budget), :failed, :inactive
    def call
      return :claimed unless claim!

      begin
        @source.reload
        return :inactive unless @source.state == "active"

        run
      ensure
        release!
      end
    end

    private

    def now = @clock.call

    def run
      unless funding_open?
        schedule!(now + FieldTweets.poll_interval, reason: funding_closed_reason)
        return :waiting
      end

      import_backlog!
      pages = 0
      loop do
        if @source.backlog_items.exists? || FieldTweets.import_allowance_left(@source.account, now: now).zero?
          schedule!(now + FieldTweets.poll_interval, reason: "Today's import allowance is used up; collection goes on tomorrow")
          return :waiting
        end
        unless @source.window_open? || open_window!
          schedule!(now + FieldTweets.poll_interval)
          return :done
        end
        if pages >= MAX_PAGES_PER_RUN
          schedule!(now + 1.minute)
          return :more
        end

        result = fetch_page!
        return failed!(BrokenPage.new) if result == :broken
        return result unless result == :page

        pages += 1
        import_backlog!
      end
    end

    def funding_open?
      @source.house_paid? ? FieldTweets.house_available? : FieldTweets.enabled?
    end

    def funding_closed_reason
      if !FieldTweets.enabled? then "Tweet collection is off for this house"
      elsif Setting.instance.field_tweets_house_halted_at then "Collection paid by the house is halted: #{Setting.instance.field_tweets_house_halt_reason}"
      else "Collection paid by the house isn't available yet"
      end
    end

    def open_window!
      until_time = now - LAG
      return false if until_time - @source.checkpoint_at < MIN_WINDOW

      since = [ @source.checkpoint_at - OVERLAP, @source.connected_at ].max
      @source.update!(window_since: since, window_until: until_time, window_cursor: nil, window_pages: 0)
      true
    end

    def fetch_page!
      call = FieldTweets.reserve!(@source, retry_call: @source.failure_count.positive?, now: now)
    rescue FieldTweets::LimitReached => e
      schedule!(FieldTweets.month_start(now) + 1.month, reason: e.message)
      :waiting
    else
      begin
        page = client.search(@source.query_for(@source.window_since, @source.window_until), cursor: @source.window_cursor)
      rescue TwitterApiIo::Error => e
        call.fail!(e)
        return failed!(e)
      end

      process_page!(page, call)
    end

    def client
      @client ||= @client_factory.call(@source.house_paid? ? FieldTweets.house_key : @source.api_key)
    end

    def process_page!(page, call)
      fetched_at = now
      rejected = 0
      attrs = page.tweets.filter_map do |tweet|
        FieldTweet.attributes_from(tweet, fetched_at: fetched_at)
      rescue FieldTweet::Invalid
        rejected += 1
        nil
      end
      # The query already leaves reposts out unless asked for; this only
      # guards against the provider including one anyway.
      attrs.reject! { it[:is_repost] } unless @source.include_reposts

      FieldTweetSource.transaction do
        ids = attrs.map { it[:provider_tweet_id] }
        known = FieldTweet.where(account_id: @source.account_id, provider_tweet_id: ids).pluck(:provider_tweet_id) +
          @source.backlog_items.where(provider_tweet_id: ids).pluck(:provider_tweet_id)
        fresh = attrs.reject { known.include?(it[:provider_tweet_id]) }.uniq { it[:provider_tweet_id] }
        if fresh.any?
          FieldTweetBacklogItem.insert_all(fresh.map { |item|
            { field_tweet_source_id: @source.id, provider_tweet_id: item[:provider_tweet_id], posted_at: item[:posted_at], attrs: item }
          }, unique_by: :index_field_tweet_backlog_on_source_and_tweet)
        end

        @source.update!(window_rejected: @source.window_rejected + rejected) if rejected.positive?
        result = advance_window!(page, attrs)
        @source.update!(failure_count: 0, last_success_at: fetched_at, state_reason: nil) unless result == :broken
        call.settle!(returned: page.tweets.size, already_stored: page.tweets.size - fresh.size - rejected,
          queued: fresh.size, rejected: rejected)
        result
      end
    end

    # => :page, or :broken when the provider says there's more without a
    # cursor that leads anywhere new (the window and its cursor stay as they
    # were; tweets from this page are kept).
    def advance_window!(page, attrs)
      return :broken if page.has_next_page && (page.next_cursor.blank? || page.next_cursor == @source.window_cursor || page.tweets.empty?)

      more = page.has_next_page
      pages = @source.window_pages + 1

      if more && pages >= MAX_WINDOW_PAGES
        # Newest first: what's left is the window's older end.
        oldest = attrs.map { it[:posted_at] }.min || @source.window_until
        record_gap!(@source.window_since, oldest)
        complete_window!
      elsif more
        @source.update!(window_cursor: page.next_cursor, window_pages: pages)
      else
        complete_window!
      end
      :page
    end

    # A window with unreadable tweets in it isn't certified as collected: the
    # whole window is kept as a gap.
    def complete_window!
      record_gap!(@source.window_since, @source.window_until) if @source.window_rejected.positive?
      @source.update!(checkpoint_at: @source.window_until, window_since: nil, window_until: nil, window_cursor: nil,
        window_pages: 0, window_rejected: 0)
    end

    def record_gap!(since, until_time)
      @source.update!(gap_since: [ @source.gap_since, since ].compact.min, gap_until: [ @source.gap_until, until_time ].compact.max)
    end

    def failed!(error)
      if error.funding?
        if @source.house_paid?
          FieldTweets.halt_house!("TwitterAPI.io refused the house key (#{error.status})", now: now)
          schedule!(now + FieldTweets.poll_interval, reason: funding_closed_reason)
        else
          # Never the house's key instead: the account chose its own.
          @source.needs_attention!("TwitterAPI.io refused this account's key (#{error.status}). Replace it, or remove it to use the house's allowance.")
        end
      elsif error.status == 400 && @source.window_cursor.present?
        # Most likely a cursor gone stale while the window waited: page the
        # same window again from its start. Tweets already kept are counted
        # and skipped.
        @source.update!(window_cursor: nil, window_pages: 0)
        retry_later!("The provider rejected the saved page cursor; the window restarts")
      elsif error.transient?
        retry_later!("#{error.message}; trying again later")
      else
        @source.needs_attention!("TwitterAPI.io rejected the search (#{error.status})")
      end
      :failed
    end

    def retry_later!(reason)
      failures = @source.failure_count + 1
      if failures >= MAX_FAILURES
        @source.update!(failure_count: failures)
        @source.needs_attention!("#{reason}. Stopped after #{failures} failures in a row.")
      else
        backoff = [ FieldTweets.poll_interval * (2**(failures - 1)), MAX_BACKOFF ].min
        @source.update!(failure_count: failures)
        schedule!(now + backoff, reason: reason)
      end
    end

    def schedule!(time, reason: nil)
      @source.update!(next_attempt_at: time, state_reason: reason&.first(300))
    end

    # Oldest first, within the day's allowance. Each tweet in its own
    # transaction with the removal of its backlog row.
    def import_backlog!
      allowance = FieldTweets.import_allowance_left(@source.account, now: now)
      return if allowance.zero?

      imported = 0
      @source.backlog_items.oldest_first.limit(allowance).each do |item|
        FieldTweet.transaction do
          attributes = item.attrs.symbolize_keys
          unless FieldTweet.exists?(account_id: @source.account_id, provider_tweet_id: attributes[:provider_tweet_id])
            FieldTweet.create!(attributes.merge(account_id: @source.account_id, field_tweet_source: @source))
            imported += 1
          end
          item.delete
        end
      end
      imported
    end

    def claim!
      @claimed_at = now
      FieldTweetSource.where(id: @source.id)
        .where("sync_claimed_at IS NULL OR sync_claimed_at < ?", @claimed_at - CLAIM_TTL)
        .update_all(sync_claimed_at: @claimed_at) == 1
    end

    def release!
      FieldTweetSource.where(id: @source.id, sync_claimed_at: @claimed_at).update_all(sync_claimed_at: nil)
    end

  end
end
