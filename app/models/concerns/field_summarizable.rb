# A Field file or recording that the house summarises once its words can be
# read (FieldItems::SummarizeJob): summary_short is a few words for one compact
# line, summary_long one sentence for a two-line slot. The page picks one.
#
# Each including model says what its words are (summary_source) and which of
# its rows have words at all (summary_readable). Provenance describes the
# actual inference input, not whatever words happen to be present at write-back.
# Human recording corrections may schedule a delayed stale check; other input
# changes only affect freshness. A person can always request a new summary.
module FieldSummarizable

  extend ActiveSupport::Concern

  MAX_ATTEMPTS = 3
  # A claim older than this is a job that died mid-call; the sweep may retry it.
  CLAIM_TTL = 15.minutes
  REFRESH_DELAY = 30.minutes

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

  # Old output remains visible during regeneration. Legacy output has no
  # provenance; don't pretend it is current or turn it into an archive backfill.
  def summary_freshness
    return nil unless summary_short.present? || summary_long.present?
    return "unknown" unless summary_input_digest.present?

    summary_input_digest == FieldSummaries.current_input_digest(self) ? "current" : "stale"
  end

  def enqueue_summary
    FieldItems::SummarizeJob.perform_later(self) if FieldSummaries.enabled? && summarizable? && !summarized?
  end

  # Under the row lock: take one of the item's few calls. false when there is
  # nothing to do or another call holds a fresh claim.
  def claim_summary!(now: Time.current)
    with_lock do
      take_summary_claim!(now:)
    end
  end

  # Admit a delayed refresh and take its claim atomically. The input digest
  # records the budget already admitted, so duplicate delayed jobs cannot
  # repeatedly reset the three-attempt cap. :busy asks the job for a bounded
  # recheck, including when the in-flight call hasn't stored provenance yet.
  def claim_stale_summary!(now: Time.current)
    with_lock do
      next false unless FieldSummaries.enabled? && summarizable?
      next false unless summary_refresh_due_at
      next :waiting if summary_refresh_due_at > now
      next :busy if summary_claim_fresh?(now:)
      next false unless summary_short.present? || summary_long.present?

      digest = FieldSummaries.current_input_digest(self)
      if digest == summary_input_digest
        update_columns(summary_refresh_due_at: nil)
        next false
      end

      if summary_refresh_digest != digest
        update_columns(summarized_at: nil, summary_attempts: 0, summary_claimed_at: nil,
          summary_claim_token: nil, summary_refresh_digest: digest)
      elsif summarized?
        # A call can have captured a different input after admission (and
        # before it changed back). Retry within this budget, never reset it.
        update_columns(summarized_at: nil)
      end
      take_summary_claim!(now:)
    end
  end

  # Explicit human edit call sites only, not an after_update hook. This also
  # waits for an enclosing controller transaction and disappears on rollback.
  # The marker is the earliest outstanding human check, NOT a sliding debounce:
  # Further edits never postpone a future marker. Once its time has passed,
  # an edit during regeneration starts a new thirty-minute window.
  def schedule_summary_refresh
    update_columns(summary_refresh_due_at: Time.current + REFRESH_DELAY) unless summary_refresh_due_at&.future?
    ActiveRecord.after_all_transactions_commit do
      FieldItems::RefreshSummaryJob.set(wait: REFRESH_DELAY).perform_later(self)
    end
  end

  # A human changed the source while a call was running. Its completion can
  # arrange a check even after the one TTL recheck was spent. No marker means
  # no human authorization: a voice fan-out alone must never enqueue.
  def enqueue_authorized_summary_check
    return unless summary_refresh_due_at

    due_at = summary_refresh_due_at
    ActiveRecord.after_all_transactions_commit do
      FieldItems::RefreshSummaryJob.set(wait_until: [ due_at, Time.current ].max).perform_later(self)
    end
  end

  # Derived data, not an edit: update_columns keeps updated_at, then an open
  # Field page is told to refresh. Ignored if the item was discarded or
  # summarised meanwhile.
  def store_summary!(short:, long:, input_digest:, claim:, now: Time.current)
    stored = with_lock do
      next false unless kept? && !summarized? && summary_claim_token == claim && claim.present?

      update_columns(summary_short: short, summary_long: long, summary_input_digest: input_digest,
        summarized_at: now, summary_claimed_at: nil, summary_claim_token: nil)
      true
    end
    broadcast_refresh if stored
    enqueue_authorized_summary_check if stored
    stored
  end

  # A person asked for the summary to be written again. The old one stays on
  # show until the new one is stored. Refused (false) while a call is already
  # in flight, so pressing refresh repeatedly costs at most one call at a time.
  # The attempt count starts again, since this is a fresh request.
  def request_resummary!(now: Time.current)
    requested = with_lock do
      next false unless summarizable?
      next false if summary_claim_fresh?(now:)

      update_columns(summarized_at: nil, summary_attempts: 0, summary_claimed_at: nil,
        summary_claim_token: nil, summary_refresh_digest: FieldSummaries.current_input_digest(self),
        summary_refresh_due_at: nil)
      true
    end
    return false unless requested

    FieldItems::SummarizeJob.perform_later(self)
    broadcast_refresh
    true
  end

  # Waiting for a summary that is coming: queued, being written (the last
  # attempt included: the count goes up when the call starts), or due a retry.
  def summary_pending?(now: Time.current)
    return false unless FieldSummaries.enabled? && summarizable? && !summarized?

    summary_attempts < MAX_ATTEMPTS || summary_claim_fresh?(now:)
  end

  # Every attempt was used and none worked: nothing more is coming unless a
  # person asks again. Only shown where there is an older summary to keep.
  def summary_failed?(now: Time.current)
    summarizable? && !summarized? && summary_attempts >= MAX_ATTEMPTS && !summary_claim_fresh?(now:)
  end

  def summary_claim_fresh?(now: Time.current) = summary_claimed_at.present? && summary_claimed_at > now - CLAIM_TTL

  # A call failed. An open page is told, so a last failure ends its "writing"
  # state rather than leaving it waiting for a summary that won't come.
  def release_summary_claim!(claim:)
    released = with_lock do
      next false unless claim.present? && summary_claim_token == claim

      update_columns(summary_claimed_at: nil, summary_claim_token: nil)
      true
    end
    broadcast_refresh if released
    released
  end

  private

  # Called only under the row lock. Return the owning token, not just true:
  # an expired worker must not store over, or release, a newer worker's claim.
  def take_summary_claim!(now:)
    if kept? && summary_source_blank? && summary_attempts < MAX_ATTEMPTS
      update_columns(summary_attempts: MAX_ATTEMPTS, summary_claimed_at: nil, summary_claim_token: nil)
      return false
    end
    return false unless summarizable? && !summarized? && summary_attempts < MAX_ATTEMPTS
    return false if summary_claim_fresh?(now:)

    token = SecureRandom.uuid
    update_columns(summary_claimed_at: now, summary_claim_token: token, summary_attempts: summary_attempts + 1)
    token
  end

end
