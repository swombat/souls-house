# Runs the held-out check over an account's prints (FieldVoiceprints::
# Validation) after any of them changes, then matches again every recording
# with someone left to guess at, if which prints may guess has changed.
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
      FieldVoiceprints::Validation.run!(account)
      after = active(account)
      return if after == before || after.empty? || !FieldVoiceprints.enabled_for?(account)

      FieldVoiceprints::Identification.recordings_to_match(account).find_each do |recording|
        FieldRecordings::IdentifyJob.perform_later(recording.id)
      end
    end

    private

    def active(account)
      FieldVoiceprints::Identification.active_prints(account).map { |print| [ print.field_voice_id, print.generation ] }.sort
    end

  end
end
