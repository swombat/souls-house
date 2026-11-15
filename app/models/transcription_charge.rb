# Audio sent to the transcriber outside a Field recording: a composer voice
# note or a Telegram voice or video message. It draws on the same allowance as
# recordings (Account#transcription_ms_limit over
# FieldRecordingReservation::WINDOW).
#
# These transcriptions are synchronous, so there is nothing to reserve and
# settle: the audio is admitted under the account lock and counted from the
# moment it is sent, whatever the transcriber answers, because a failed or
# timed-out request may still have been billed. One row per piece of audio
# (unique on source and key), so retrying the same voice note is not charged
# twice. Each send still counts toward the vendor exposure ceiling
# (FieldRecordingDispatch.exposure_ms), which bounds spend through retries.
class TranscriptionCharge < ApplicationRecord

  SOURCES = %w[voice_note telegram].freeze
  WINDOW = FieldRecordingReservation::WINDOW
  # When a file's length can't be read, assume this bitrate. Browser and
  # Telegram voice audio is rarely below it, so the estimate errs long.
  FALLBACK_BITS_PER_SECOND = 24_000

  class Refused < StandardError; end

  belongs_to :account

  validates :source, inclusion: { in: SOURCES }
  validates :source_key, presence: true
  validates :audio_ms, numericality: { only_integer: true, greater_than: 0 }

  scope :counting_at, ->(now) { where(created_at: (now - WINDOW)..) }

  def self.used_ms(account, now: Time.current)
    where(account:).counting_at(now).sum(:audio_ms)
  end

  def self.exposure_ms(account, now: Time.current)
    where(account:).counting_at(now).sum("audio_ms * attempts")
  end

  # The audio's length, measured; from its size when ffprobe can't say.
  # Returns [ms, estimated].
  def self.measure(path, byte_size:)
    ms = FieldRecording::Probe.duration_ms(path) || FieldRecording::Probe.packet_duration_ms(path)
    return [ ms, false ] if ms

    [ [ (byte_size * 8 * 1000.0 / FALLBACK_BITS_PER_SECOND).ceil, 1000 ].max, true ]
  end

  # Admit one send of this audio, or raise Refused with words for the person.
  # The first send of a piece of audio must fit the allowance; every send
  # must fit the exposure ceiling.
  def self.admit!(account:, source:, key:, path:, byte_size:, now: Time.current)
    audio_ms, estimated = measure(path, byte_size:)
    account.with_lock do
      charge = find_by(source:, source_key: key.to_s)
      exposure = FieldRecordingDispatch.exposure_ms(account, now:)
      if exposure + (charge&.audio_ms || audio_ms) > FieldRecordingDispatch.exposure_limit_ms(account)
        raise Refused, FieldRecordingDispatch::EXPOSURE_MESSAGE
      end

      if charge
        charge.increment!(:attempts)
      elsif FieldRecordingReservation.used_ms(account, now:) + audio_ms > account.transcription_ms_limit
        raise Refused, over_limit_message(account, audio_ms, now:)
      else
        charge = create!(account:, source:, source_key: key.to_s, audio_ms:, estimated:, created_at: now)
      end
      charge
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
