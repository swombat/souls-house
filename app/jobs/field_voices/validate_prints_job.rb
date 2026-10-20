# Runs the held-out check over an account's prints (FieldVoiceprints::
# Validation) after any of them changes, then matches again every recording
# with someone left to guess at, if the matching snapshot differs from the one
# they were last matched against.
module FieldVoices
  class ValidatePrintsJob < ApplicationJob

    queue_as :background

    # Several samples landing together queue one check each; a short wait lets
    # most of them find the work already done.
    def self.queue!(account)
      ActiveRecord.after_all_transactions_commit { set(wait: 15.seconds).perform_later(account.id) }
    end

    def perform(account_id)
      account = Account.find_by(id: account_id)
      return unless account

      # nil: the cohort changed while measuring. Whatever changed it queued
      # its own check, which runs after this one.
      return unless FieldVoiceprints::Validation.run!(account)
      return unless FieldVoiceprints.enabled_for?(account)
      # Unchecked prints give "maybe" hints, so any print is reason to match.
      return if FieldVoiceprints::Cohort.prints(account).empty?

      # Match again whenever the snapshot differs from the one the account's
      # recordings were last matched against, not only when this check moved
      # it: a print learned before the check, and left unchecked by it, still
      # changes what can hint (Mira's review of #479).
      key = FieldVoiceprints::Cohort.active(account).last
      return if account.field_matched_cohort == key

      account.update_columns(field_matched_cohort: key)
      FieldVoiceprints::Identification.recordings_to_match(account).find_each do |recording|
        FieldRecordings::IdentifyJob.perform_later(recording.id)
      end
    end

  end
end
