# Runs the held-out check over an account's prints (FieldVoiceprints::
# Validation) after any of them changes, then matches again every recording
# with someone left to guess at, if the matching snapshot changed.
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

      before = active(account)
      # nil: the cohort changed while measuring. Whatever changed it queued
      # its own check, which runs after this one.
      return unless FieldVoiceprints::Validation.run!(account)

      after = active(account)
      return if after == before || !FieldVoiceprints.enabled_for?(account)
      return if FieldVoiceprints::Identification.active_prints(account).empty?

      FieldVoiceprints::Identification.recordings_to_match(account).find_each do |recording|
        FieldRecordings::IdentifyJob.perform_later(recording.id)
      end
    end

    private

    # The matching snapshot: any change cleared the guesses made in the old
    # one, so match again.
    def active(account) = FieldVoiceprints::Cohort.active(account).last

  end
end
