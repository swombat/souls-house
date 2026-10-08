# One vendor dispatch of a recording (spec §3, §5). Written before the POST,
# and outlives its attempt: it's what vendor cleanup works from, even when the
# result was stale or the recording was discarded.
#
# Vendor ids are monotonic knowledge (Mira, #202 approval): once learned they
# are never overwritten by a later null, and learning an id after a cleanup
# attempt that lacked one queues the cleanup again.
class FieldRecordingDispatch < ApplicationRecord

  OUTCOMES = %w[in_flight succeeded failed superseded].freeze
  NO_ID = "no transcription id"
  EXPOSURE_WINDOW = 7.days
  # Audio the house will send for one account in a week, counting every
  # attempt, as a multiple of the account's transcription allowance. Room for
  # retries after failures, but a hard ceiling on vendor spend.
  EXPOSURE_FACTOR = 2
  EXPOSURE_MESSAGE = "This Field has sent as much audio to the transcriber as it can this week. Try again in a few days."

  belongs_to :field_recording
  belongs_to :account

  validates :outcome, inclusion: { in: OUTCOMES }
  validates :audio_ms, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  def self.exposure_ms(account, now: Time.current)
    where(account:, created_at: (now - EXPOSURE_WINDOW)..).sum(:audio_ms)
  end

  def self.exposure_limit_ms(account)
    account.recording_ms_weekly_limit * EXPOSURE_FACTOR
  end

  # Under this row's lock, the same lock the cleanup job takes, so "cleanup
  # found no id" and "the id arrived" can't miss each other.
  def learn_ids!(request_id: nil, transcription_id: nil)
    with_lock do
      changes = {}
      changes[:request_id] = request_id if request_id.present? && self.request_id.blank?
      changes[:transcription_id] = transcription_id if transcription_id.present? && self.transcription_id.blank?
      next if changes.empty?

      retrigger = changes.key?(:transcription_id) && vendor_delete_error == NO_ID
      changes[:vendor_delete_error] = nil if retrigger
      update!(changes)
      FieldRecordings::DeleteVendorTranscriptJob.perform_later(id) if retrigger
    end
  end

  # A finished vendor transcript exists for this dispatch, whatever happened
  # to the recording, so it should be deleted at the vendor.
  def needs_vendor_cleanup? = vendor_deleted_at.nil?

end
