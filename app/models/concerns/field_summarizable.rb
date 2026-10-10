# A Field file or recording that the house summarises once its words can be
# read (FieldItems::SummarizeJob): summary_short is a few words for one compact
# line, summary_long one sentence for a two-line slot. The page picks one.
#
# Each including model says what its words are (summary_source) and which of
# its rows have words at all (summary_readable). Summaries are written once and
# not redone when a title, note or speaker name changes.
module FieldSummarizable

  extend ActiveSupport::Concern

  MAX_ATTEMPTS = 3
  # A claim older than this is a job that died mid-call; the sweep may retry it.
  CLAIM_TTL = 15.minutes

  included do
    # Rows the hourly sweep should (re)queue: readable, kept, unsummarised,
    # under the attempt cap, and not claimed by a call still in flight.
    scope :summary_due, ->(now: Time.current) {
      summary_readable.kept.where(summarized_at: nil).where(summary_attempts: ...MAX_ATTEMPTS)
        .where("summary_claimed_at IS NULL OR summary_claimed_at < ?", now - CLAIM_TTL)
    }
  end

  def summarizable? = kept? && summary_source.present?

  # Read, but nothing in it but whitespace: nothing to summarise, ever.
  def summary_source_blank? = !summary_source.nil? && summary_source.blank?
  def summarized? = summarized_at.present?

  def enqueue_summary
    FieldItems::SummarizeJob.perform_later(self) if FieldSummaries.enabled? && summarizable? && !summarized?
  end

  # Under the row lock: take one of the item's few calls. false when there is
  # nothing to do or another call holds a fresh claim.
  def claim_summary!(now: Time.current)
    with_lock do
      # A blank item is retired, so it can't hold a place in the sweep's
      # oldest-first batch forever (Ken and Mira on #275).
      if kept? && summary_source_blank? && summary_attempts < MAX_ATTEMPTS
        update_columns(summary_attempts: MAX_ATTEMPTS, summary_claimed_at: nil)
        next false
      end
      next false unless summarizable? && !summarized? && summary_attempts < MAX_ATTEMPTS
      next false if summary_claimed_at && summary_claimed_at > now - CLAIM_TTL

      update_columns(summary_claimed_at: now, summary_attempts: summary_attempts + 1)
      true
    end
  end

  # Derived data, not an edit: update_columns keeps updated_at, then an open
  # Field page is told to refresh. Ignored if the item was discarded or
  # summarised meanwhile.
  def store_summary!(short:, long:, now: Time.current)
    stored = with_lock do
      next false unless kept? && !summarized?

      update_columns(summary_short: short, summary_long: long, summarized_at: now, summary_claimed_at: nil)
      true
    end
    broadcast_refresh if stored
    stored
  end

  def release_summary_claim!
    update_columns(summary_claimed_at: nil)
  end

end
