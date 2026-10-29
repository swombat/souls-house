# One public X handle an account follows into its Field (one per account for
# now). Its own posts, and by default its own replies and quote-posts;
# reposts only when asked. Not a home timeline, not other people's replies,
# not protected accounts, and no X password or cookie.
#
# Collection (FieldTweets::Sync) works in frozen search windows. checkpoint_at
# is the end of the last window whose every page was processed; the open
# window (window_since/until/cursor) is work in progress and survives
# retries, pauses and outages. The checkpoint never jumps to now after a
# failure. A stretch that couldn't be collected is kept as a gap and shown.
#
# Paid by the account's own TwitterAPI.io integration, or by the house key
# for accounts granted it (FieldTweets.funding_for). A failing own key never
# falls back to the house.
class FieldTweetSource < ApplicationRecord

  include ObfuscatesId

  # status_json and display_state only. Claim/cursor/page/failure bookkeeping
  # and attribution do not change the panel's rendered source projection.
  STREAM_STATUS_COLUMNS = %w[
    account_id handle include_replies include_quotes include_reposts
    own_monthly_usd_limit state state_reason connected_at checkpoint_at
    window_since gap_since gap_until last_success_at next_attempt_at
  ].freeze

  after_save :refresh_stream_status, if: -> { (saved_changes.keys & STREAM_STATUS_COLUMNS).any? }
  after_destroy -> { FieldTweetStream.refresh!(account_id) }

  belongs_to :account
  belongs_to :created_by, polymorphic: true, optional: true
  has_many :field_tweets, dependent: :nullify
  has_many :backlog_items, class_name: "FieldTweetBacklogItem", dependent: :delete_all

  # Save state together with its reason/retry metadata in the domain methods.
  # The stream refresh stays on the existing save callback.
  state_machine :state, initial: :active, action: nil do
    state :active, :paused, :needs_attention

    event :pause_collection do
      transition all => :paused
    end

    event :flag_attention do
      transition all => :needs_attention
    end

    event :resume_collection do
      transition all => :active
    end
  end

  normalizes :handle, with: ->(value) { value.to_s.strip.delete_prefix("@") }

  validates :handle, format: { with: FieldTweet::HANDLE, message: "must be an X handle (letters, digits and _, up to 15)" }
  validates :account_id, uniqueness: { message: "already follows a handle" }
  validates :own_monthly_usd_limit, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 100 }

  before_validation(on: :create) do
    self.connected_at ||= Time.current
    # Collection starts at connection: nothing from before is imported
    # unless a backfill is asked for.
    self.checkpoint_at ||= connected_at
    self.next_attempt_at ||= connected_at
  end

  # A provider cursor belongs to the query it came from. When what is
  # included changes, an open window is paged again from its start with the
  # new query; tweets already kept are only counted.
  before_update(if: -> { (changed & %w[include_replies include_quotes include_reposts]).any? && window_cursor.present? }) do
    self.window_cursor = nil
    self.window_pages = 0
  end

  # "own", "house" or nil: decided by the account, not the source, each time.
  def funding = FieldTweets.funding_for(account)
  def house_paid? = funding == "house"

  def window_open? = window_until.present?

  def query_for(since, until_time)
    TwitterApiIo.window_query(handle: handle, since: since, until_time: until_time,
      replies: include_replies, quotes: include_quotes, reposts: include_reposts)
  end

  # What a person sees about collection. Never the key.
  def status_json(now: Time.current)
    {
      id: to_param,
      handle: handle,
      url: "https://x.com/#{handle}",
      include_replies: include_replies,
      include_quotes: include_quotes,
      include_reposts: include_reposts,
      funding: funding,
      own_monthly_usd_limit: own_monthly_usd_limit.to_s,
      state: display_state(now),
      state_reason: state_reason,
      connected_at: connected_at.iso8601,
      collected_through: checkpoint_at.iso8601,
      backlog: backlog_items.count,
      gap: (gap_since && { since: gap_since.iso8601, until: gap_until&.iso8601 }),
      last_success_at: last_success_at&.iso8601,
      next_attempt_at: next_attempt_at&.iso8601,
      imported_today: FieldTweets.imported_today(account, now: now),
      daily_import_cap: FieldTweets.daily_import_cap
    }
  end

  # active is split for people: waiting (on an allowance, a budget, a retry
  # or the house; state_reason says which), behind (backlogged), or syncing.
  def display_state(now = Time.current)
    return state unless state == "active"
    return "waiting" if state_reason.present?
    return "backlogged" if backlog_items.exists? || (window_since && window_since < now - 1.hour)

    "syncing"
  end

  def pause!(reason)
    pause_collection!
    update!(state_reason: reason.to_s.first(300))
  end

  def needs_attention!(reason)
    flag_attention!
    update!(state_reason: reason.to_s.first(300))
  end

  # A person's act: start again from where collection stopped (the open
  # window and backlog are kept, not dropped).
  def resume!(now: Time.current)
    resume_collection!
    update!(state_reason: nil, failure_count: 0, next_attempt_at: now)
  end

  private

  private :pause_collection, :pause_collection!, :flag_attention, :flag_attention!,
    :resume_collection, :resume_collection!

  def refresh_stream_status
    FieldTweetStream.refresh!([ account_id, *saved_change_to_account_id ])
  end

end
