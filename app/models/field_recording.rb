# A recording someone brought into an account's Field, to be transcribed with
# its speakers separated. Spec: docs/2026-10-08-field-recordings-spec.md.
#
# Lifecycle (§5a): every state change happens under this row's lock and
# rechecks, inside the lock, what it was started under (kept, status, and for
# vendor work the attempt token). Terminal states clear the attempt token so no
# stale worker can move a recording out of one. Lock order is account, then
# recording.
#
# Deleting discards, as for Field files: the row and bytes are kept, and
# HidesDiscardedBlobs stops issued blob URLs from serving the audio.
class FieldRecording < ApplicationRecord

  include Discard::Model
  include Broadcastable
  include ObfuscatesId
  include SyncAuthorizable
  include FieldRecording::Transcription

  class NotRetryable < StandardError; end

  MAX_BYTES = 2.gigabytes # Scribe's limit for a file fetched by URL
  MAX_BYTES_LABEL = "2 GB"
  MAX_NOTE_LENGTH = FieldFile::MAX_NOTE_LENGTH
  MAX_SPEAKERS = 32 # Scribe's num_speakers ceiling
  MAX_DISPATCHES = 3

  MAX_SOURCE_PATH_LENGTH = 1000
  MAX_IMPORT_KEY_LENGTH = 200
  LANGUAGE_CODE = /\A[a-z]{2,3}(-[A-Za-z0-9]{2,8})*\z/

  STATUSES = %w[probing queued transcribing ready rejected failed].freeze
  # "vendor": transcribed here. "supplied": arrived with its transcript (spec
  # docs/2026-10-09-field-supplied-transcripts.md), never sent anywhere.
  TRANSCRIPT_SOURCES = %w[vendor supplied].freeze
  TERMINAL_STATUSES = %w[ready rejected failed].freeze
  RETRYABLE_STATUSES = %w[failed rejected].freeze

  belongs_to :account
  belongs_to :uploaded_by, polymorphic: true, optional: true
  # Provenance only: destroying the original (e.g. with its account) leaves a
  # retry standing with no back-reference, in the model and in the database.
  belongs_to :retried_from, class_name: "FieldRecording", optional: true
  has_many :retries, class_name: "FieldRecording", foreign_key: :retried_from_id,
    inverse_of: :retried_from, dependent: :nullify
  has_one :reservation, class_name: "FieldRecordingReservation", dependent: :destroy

  has_one_attached :audio

  validates :title, presence: true, length: { maximum: 200 }
  validates :note, length: { maximum: MAX_NOTE_LENGTH }
  validates :status, inclusion: { in: STATUSES }
  validates :expected_speakers, numericality: { only_integer: true, in: 1..MAX_SPEAKERS }, allow_nil: true
  validates :transcript_source, inclusion: { in: TRANSCRIPT_SOURCES }
  validates :source_path, length: { maximum: MAX_SOURCE_PATH_LENGTH }
  validates :import_key, length: { maximum: MAX_IMPORT_KEY_LENGTH }, allow_nil: true
  # Scribe's own codes are checked by Scribe; a supplied one is the caller's.
  validates :language_code, format: { with: LANGUAGE_CODE }, allow_nil: true, if: :supplied?
  # Bytes are required when a recording is made. A rejected recording's audio
  # is later purged on purpose (OrphanSweepJob) while the row stays, and its
  # title and note must remain editable.
  validate :audio_present_and_bounded, on: :create

  before_validation :default_title_from_filename
  before_validation :normalise_provenance

  broadcasts_to :account

  scope :newest_first, -> { order(created_at: :desc, id: :desc) }

  STATUSES.each do |name|
    define_method(:"#{name}?") { status == name }
  end

  def terminal? = TERMINAL_STATUSES.include?(status)
  def supplied? = transcript_source == "supplied"

  # Made with its transcript, which arrived with the audio (docs/2026-10-09-
  # field-supplied-transcripts.md). It lands ready, without passing through
  # admission or dispatch, so no dispatch guard reaches it; each has a home:
  #
  # - size: the upload declaration and the create validation, as for any
  #   recording (2 GB);
  # - allowance: not reserved. The weekly allowance meters what is sent to
  #   the transcriber, and nothing is;
  # - language: the caller's code, format-checked, not detected;
  # - speakers: at most SuppliedTranscript::MAX_SPEAKERS distinct labels.
  #   expected_speakers steers the diarizer and is not kept, since there is
  #   none;
  # - retry: never offered (it is never failed or rejected).
  #
  # Word timings don't exist, so transcript_words stays empty and speakers
  # have no talk time or clip; the voice-recognition and suggestion jobs are
  # never queued for it. Called inside the create transaction.
  def store_supplied_transcript!(turns)
    raise ArgumentError, "not a supplied recording" unless supplied?

    FieldRecording::SuppliedTranscript.speakers(turns).each { |attributes| speakers.create!(attributes) }
    speakers.reset
    self.transcript_turns = turns
    self.transcript_words = []
    self.transcript_text = render_transcript_text
    update!(status: "ready", ready_at: Time.current, expected_speakers: nil)
  end

  # Probe of a supplied recording: the duration only, for display. Its status
  # is already final and nothing is reserved.
  def record_duration!(probed_ms)
    with_lock do
      next false unless probed_ms && kept? && supplied? && duration_ms.nil?

      update!(duration_ms: probed_ms)
    end
  end

  # Probe found a duration: reserve allowance or refuse (§6). Account lock
  # first, then this row, so two probes finishing together are serialised.
  # Returns :admitted, :rejected or :skipped.
  def admit!(duration_ms, now: Time.current)
    account.with_lock do
      lock!
      next :skipped unless kept? && probing?
      next :skipped if reservation.present?

      used = FieldRecordingReservation.used_ms(account, now:)
      if used + duration_ms > account.recording_ms_weekly_limit
        update!(status: "rejected", duration_ms:, attempt_token: nil,
          failure_reason: FieldRecordingReservation.over_limit_message(account, duration_ms, now:))
        :rejected
      else
        create_reservation!(account:, audio_ms: duration_ms, state: "pending", reserved_at: now)
        update!(status: "queued", duration_ms:)
        :admitted
      end
    end
  end

  # Probe couldn't read the file. No allowance was reserved.
  def reject_unreadable!(reason)
    with_lock do
      next false unless kept? && probing?
      update!(status: "rejected", failure_reason: reason, attempt_token: nil)
    end
  end

  # Discard and settle in one locked step (§5): clear the attempt so every
  # in-flight step fails its guard, then settle the reservation. Allowance is
  # given back only if nothing was ever sent to the transcriber. Once a
  # dispatch has gone out the vendor work is paid for, so the reservation is
  # consumed: otherwise upload, discard mid-transcription, repeat would buy
  # unbounded transcription with an allowance that never runs down.
  def discard_and_settle!(now: Time.current)
    with_lock do
      next false if discarded?
      supersede_in_flight_dispatches!
      self.attempt_token = nil
      discard!
      settle_reservation_after_discard!(now:)
      true
    end
  end

  def settle_reservation_after_discard!(now: Time.current)
    return unless reservation

    if dispatch_count.positive?
      reservation.consume!(now:)
    else
      reservation.release!(reason: "discarded", now:)
    end
  end

  # "Try again" (§4): an internal path that attaches the same blob to a new
  # recording, which then goes through probe and admission like any other.
  # The upload endpoint's "unattached blobs only" rule is not involved.
  def retry!(by:)
    with_lock do
      raise NotRetryable unless kept? && RETRYABLE_STATUSES.include?(status) && audio.attached?

      account.field_recordings.create!(
        title:, note:, expected_speakers:, uploaded_by: by, retried_from: self, audio: audio.blob
      )
    end
  end

  def uploader_name
    case uploaded_by
    when User then uploaded_by.full_name.presence || uploaded_by.email_address.split("@").first
    when Agent then uploaded_by.name
    end
  end

  def uploader_kind
    case uploaded_by
    when User then "human"
    when Agent then "resident"
    end
  end

  def filename = audio.attached? ? audio.filename.to_s : nil
  def byte_size = audio.attached? ? audio.byte_size : nil

  private

  def normalise_provenance
    self.source_path = source_path.to_s.strip.presence
    self.import_key = import_key.to_s.strip.presence
    self.language_code = language_code.to_s.strip.presence
  end

  def default_title_from_filename
    self.title = title.to_s.strip
    self.title = audio.filename.to_s.truncate(200) if title.blank? && audio.attached?
  end

  def audio_present_and_bounded
    unless audio.attached?
      errors.add(:audio, "must be attached")
      return
    end

    errors.add(:audio, "must be #{MAX_BYTES_LABEL} or smaller") if audio.byte_size > MAX_BYTES
  end

end
