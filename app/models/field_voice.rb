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

  private

  def name_unique_among_kept
    others = account.field_voices.kept.named_like(name)
    others = others.where.not(id:) if persisted?
    errors.add(:name, "is already a voice in this Field") if others.exists?
  end

  def rerender_transcripts
    FieldRecordings::RerenderTranscriptsJob.perform_later(id)
  end

end
