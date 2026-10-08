# Who a name on a transcript refers to, within one account (spec §3, §7).
# Print-optional: naming someone stores a name, nothing biometric. Linking two
# speakers to one voice is always an explicit choice, never name equality, and
# a voice is linked to a member (user_id) only by "this is me" or by picking
# that member.
class FieldVoice < ApplicationRecord

  include Discard::Model
  include ObfuscatesId

  MAX_NAME_LENGTH = 100

  belongs_to :account
  belongs_to :user, optional: true
  belongs_to :created_by, polymorphic: true, optional: true
  has_many :speakers, class_name: "FieldRecordingSpeaker", dependent: :nullify
  has_one :voiceprint, class_name: "FieldVoiceprint", dependent: :destroy
  has_many :enrolments, class_name: "FieldVoiceEnrolment", dependent: :destroy

  validates :name, presence: true, length: { maximum: MAX_NAME_LENGTH }
  validate :name_unique_among_kept, if: -> { kept? && (new_record? || will_save_change_to_name?) }

  before_validation { self.name = name.to_s.squish }
  after_update_commit :rerender_transcripts, if: -> { saved_change_to_name? }

  scope :named_like, ->(name) { where("lower(name) = ?", name.to_s.squish.downcase) }

  # The account member's own voice, made on first use. "Never by name
  # equality": if the member's name is already taken by an unlinked voice, the
  # new voice gets a distinguishing name instead of absorbing that one.
  def self.for_member!(account:, user:, by:)
    existing = account.field_voices.kept.find_by(user:)
    return existing if existing

    base = user.full_name.presence || user.email_address.split("@").first
    name = account.field_voices.kept.named_like(base).exists? ? "#{base} (#{user.email_address.split('@').first})" : base
    account.field_voices.create!(name:, user:, created_by: by)
  rescue ActiveRecord::RecordNotUnique
    account.field_voices.kept.find_by!(user:)
  end

  # Where this voice was last named, for "Same Priya as in Board call?".
  def last_named_in
    speakers.joins(:field_recording).merge(FieldRecording.kept).order(named_at: :desc).first&.field_recording
  end

  # The print exists and is the one this voice currently stands behind.
  def remembered?
    print = voiceprint
    print.present? && print.generation == print_generation
  end

  # Forget this voice's print (spec §9). Always allowed: no gate, no current
  # print and no pending consent are needed, because revocation must work
  # whatever state recognition is in. Under the voice lock: the generation
  # moves on (so nothing in flight can match, even after a later re-enrol),
  # the print row is destroyed, pending enrolments and their samples go, and
  # recognitions pointing here are cleared. Names people gave stay.
  def forget!
    with_lock { forget_locked! }
  end

  # Deleting the name itself, atomically: under account → recordings → voice
  # (the same order every enrolment and write-back takes), forget the print,
  # return its speakers to "Speaker N", discard the voice and re-render the
  # transcripts. Nothing can enrol or write a print for it in between.
  def delete_identity!
    recordings = FieldRecording.where(id: speakers.select(:field_recording_id)).order(:id).to_a
    account.with_lock do
      recordings.each(&:lock!)
      lock!
      forget_locked!
      speakers.update_all([ "field_voice_id = NULL, naming_source = NULL, named_by_type = NULL, named_by_id = NULL, " \
                            "named_at = NULL, decision_generation = decision_generation + 1" ])
      FieldRecordingSpeaker.where(suggested_voice_id: id).update_all(suggested_voice_id: nil, suggested_name: nil,
        suggestion_quote: nil, suggestion_quote_ms: nil, suggestion_source: nil, suggested_at: nil)
      discard!
      recordings.each { |recording| recording.update!(transcript_text: recording.render_transcript_text) if recording.ready? }
    end
  end

  private

  def forget_locked!
    update_columns(print_generation: print_generation + 1, updated_at: Time.current)
    FieldVoiceprint.where(field_voice_id: id).destroy_all
    FieldVoiceEnrolment.where(field_voice_id: id).find_each(&:destroy!)
    FieldRecordingSpeaker.where(recognised_voice_id: id)
      .update_all(recognised_voice_id: nil, recognition_confidence: nil, recognition_print_generation: nil,
        recognition_decision_generation: nil)
  end

  def name_unique_among_kept
    others = account.field_voices.kept.named_like(name)
    others = others.where.not(id:) if persisted?
    errors.add(:name, "is already a voice in this Field") if others.exists?
  end

  def rerender_transcripts
    FieldRecordings::RerenderTranscriptsJob.perform_later(id)
  end

end
