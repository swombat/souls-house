# Audio sent to the transcriber outside a Field recording: a composer voice
# note or a Telegram voice or video message. It draws on the same allowance as
# recordings (Account#transcription_ms_limit over
# FieldRecordingReservation::WINDOW).
#
# These transcriptions are synchronous, so there is nothing to reserve and
# settle: the audio is admitted under the account lock and counted from the
# moment it is sent, whatever the transcriber answers, because a failed or
# timed-out request may still have been billed.
#
# One row per send. The first send of a piece of audio (retry: false, unique
# on source and key) is what the allowance counts, for 30 days from that send.
# A retry of the same audio adds a row with retry: true, which the allowance
# ignores and the vendor exposure ceiling (FieldRecordingDispatch.exposure_ms)
# counts for 30 days from the retry itself, so spend through retries stays
# bounded for as long as it is recent.
#
# Audio whose length can't be read is refused, not guessed: a guess could be
# short, and this is a ceiling.
class TranscriptionCharge < ApplicationRecord

  SOURCES = %w[voice_note telegram].freeze
  WINDOW = FieldRecordingReservation::WINDOW
  UNREADABLE = "This audio's length couldn't be read, so it can't be transcribed.".freeze

  class Refused < StandardError; end
  class Unreadable < Refused; end

  belongs_to :account

  validates :source, inclusion: { in: SOURCES }
  validates :source_key, presence: true
  validates :audio_ms, numericality: { only_integer: true, greater_than: 0 }

  scope :counting_at, ->(now) { where(created_at: (now - WINDOW)..) }
  scope :first_sends, -> { where(retry: false) }

  def self.used_ms(account, now: Time.current)
    where(account:).first_sends.counting_at(now).sum(:audio_ms)
  end

  def self.exposure_ms(account, now: Time.current)
    where(account:).counting_at(now).sum(:audio_ms)
  end

  # The audio's length in milliseconds, measured; nil when it can't be read.
  def self.measure(path)
    FieldRecording::Probe.duration_ms(path) || FieldRecording::Probe.packet_duration_ms(path)
  end

  # Admit one send of this audio, or raise Refused with words for the person.
  # The first send of a piece of audio must fit the allowance; every send
  # must fit the exposure ceiling.
  def self.admit!(account:, source:, key:, path:, now: Time.current)
    audio_ms = measure(path) or raise Unreadable, UNREADABLE
    account.with_lock do
      first = first_sends.find_by(source:, source_key: key.to_s)
      audio_ms = first.audio_ms if first
      if FieldRecordingDispatch.exposure_ms(account, now:) + audio_ms > FieldRecordingDispatch.exposure_limit_ms(account)
        raise Refused, FieldRecordingDispatch::EXPOSURE_MESSAGE
      end
      if first.nil? && FieldRecordingReservation.used_ms(account, now:) + audio_ms > account.transcription_ms_limit
        raise Refused, over_limit_message(account, audio_ms, now:)
      end

      create!(account:, source:, source_key: key.to_s, audio_ms:, retry: first.present?, created_at: now)
    end
  end

  def self.over_limit_message(account, needed_ms, now: Time.current)
    left = [ account.transcription_ms_limit - FieldRecordingReservation.used_ms(account, now:), 0 ].max
    message = "Transcription has stopped for now: this account has #{FieldRecordingReservation.format_duration(left)} " \
              "of its 30-day transcription allowance left, and this audio is #{FieldRecordingReservation.format_duration(needed_ms)}."
    if needed_ms <= account.transcription_ms_limit && (at = FieldRecordingReservation.room_at(account, needed_ms, now:))
      "#{message} Room frees up gradually; enough for this by about #{at.strftime('%a %-d %b, %H:%M')} UTC."
    else
      message
    end
  end

end
