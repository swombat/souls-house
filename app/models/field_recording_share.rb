# A link to read one recording's transcript without an account (Daniel,
# 2026-10-21). Anyone holding the URL can read it until it expires or is
# revoked, and only while the recording is kept and ready. The page shows the
# transcript as it stands, so corrections and names made later show through.
#
# The token appears once, in the URL handed back when the link is made; only
# its digest is kept.
class FieldRecordingShare < ApplicationRecord

  include ObfuscatesId

  # What the person sharing picks from. "1d" is the default.
  EXPIRIES = {
    "1h" => 1.hour,
    "1d" => 1.day,
    "1w" => 1.week,
    "never" => nil
  }.freeze
  DEFAULT_EXPIRY = "1d"
  TOKEN_PREFIX = "sht_"
  TOKEN_FORMAT = /\Asht_[A-Za-z0-9_-]{43}\z/
  # Live links per recording; old ones can be revoked to make room.
  MAX_ACTIVE_PER_RECORDING = 20

  class Invalid < StandardError; end

  belongs_to :field_recording
  belongs_to :account
  belongs_to :created_by, class_name: "User", optional: true

  validates :token_digest, presence: true, uniqueness: true

  scope :active, -> { where(revoked_at: nil).where("expires_at IS NULL OR expires_at > ?", Time.current) }

  attr_reader :token

  # Makes a link and returns it with #token set (the only time it is known).
  def self.issue!(recording:, user:, expiry: DEFAULT_EXPIRY)
    expiry = expiry.presence || DEFAULT_EXPIRY
    raise Invalid, "Choose 1 hour, 1 day, 1 week or never." unless EXPIRIES.key?(expiry)

    recording.with_lock do
      raise Invalid, "Only a finished transcript can be shared." unless recording.kept? && recording.ready?
      if recording.shares.active.count >= MAX_ACTIVE_PER_RECORDING
        raise Invalid, "This recording already has #{MAX_ACTIVE_PER_RECORDING} live links. Revoke one first."
      end

      token = TOKEN_PREFIX + SecureRandom.urlsafe_base64(32)
      duration = EXPIRIES.fetch(expiry)
      share = recording.shares.create!(
        account: recording.account,
        created_by: user,
        token_digest: digest(token),
        expires_at: duration && Time.current + duration
      )
      share.instance_variable_set(:@token, token)
      share
    end
  end

  # The share a URL token names, whatever its state; nil for anything that
  # isn't one of ours. Callers check #viewable? before showing anything.
  def self.find_by_token(token)
    return unless token.is_a?(String) && token.match?(TOKEN_FORMAT)

    find_by(token_digest: digest(token))
  end

  def self.digest(token) = Digest::SHA256.hexdigest(token)

  def expired? = expires_at.present? && expires_at <= Time.current
  def revoked? = revoked_at.present?
  def active? = !expired? && !revoked?

  # Also false once the recording is deleted (discarded) or stops being ready
  # (a retry): the link never outlives what it points at.
  def viewable?
    active? && field_recording.kept? && field_recording.ready?
  end

  def revoke!
    update!(revoked_at: Time.current) unless revoked?
  end

  # Counted without touching updated_at, and without a lock: a count that
  # misses a simultaneous view is fine.
  def record_view!
    self.class.where(id:).update_all([ "view_count = view_count + 1, last_viewed_at = ?", Time.current ])
  end

  def as_list_json
    {
      id: to_param,
      expires_at: expires_at&.iso8601,
      created_at: created_at.iso8601,
      created_by_name: created_by&.display_name,
      view_count:,
      last_viewed_at: last_viewed_at&.iso8601
    }
  end

end
