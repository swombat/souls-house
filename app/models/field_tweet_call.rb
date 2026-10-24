# One paid TwitterAPI.io call for a tweet stream. Reserved before the call
# with the most a page can cost (FieldTweets.reserve!), then settled with
# what it returned. A call the provider answered with an error status is
# charged the per-call minimum (whether errors are billed isn't documented;
# an assumption, not reconciled spend). One with no answer at all (timeout,
# dropped connection), or a success whose body couldn't be read, is
# uncertain and keeps its whole reservation. One given back before anything was sent is failed
# at no charge.
#
# returned_count is every tweet the provider returned (what is billed),
# already_stored_count those the account already had (overlap and retries),
# queued_count the new ones, rejected_count those that couldn't be read.
class FieldTweetCall < ApplicationRecord

  STATUSES = %w[reserved settled failed uncertain].freeze
  FUNDINGS = %w[house own].freeze

  belongs_to :account
  belongs_to :field_tweet_source, optional: true

  validates :status, inclusion: { in: STATUSES }
  validates :funding, inclusion: { in: FUNDINGS }
  validates :charge_usd, numericality: { greater_than_or_equal_to: 0 }

  # Calls that count against a ceiling: anything charged or still reserved.
  scope :charged, -> { where("charge_usd > 0") }
  scope :since, ->(time) { where(created_at: time..) }

  def settle!(returned:, already_stored:, queued:, rejected: 0)
    with_lock do
      return unless status == "reserved"

      update!(status: "settled", charge_usd: TwitterApiIo.charge_for(returned),
        returned_count: returned, already_stored_count: already_stored, queued_count: queued, rejected_count: rejected)
    end
  end

  def fail!(error)
    with_lock do
      return unless status == "reserved"

      http_status = (error.status if error.respond_to?(:status))
      if http_status && !(200..299).cover?(http_status)
        update!(status: "failed", charge_usd: TwitterApiIo::MIN_USD_PER_CALL, http_status: http_status, error: error.message.to_s.first(300))
      else
        update!(status: "uncertain", http_status: http_status, error: error.message.to_s.first(300))
      end
    end
  end

  def release!
    with_lock { update!(status: "failed", charge_usd: 0) if status == "reserved" }
  end

end
