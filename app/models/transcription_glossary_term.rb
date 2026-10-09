# One word or phrase in an account's transcription glossary. Scribe's limits
# for a keyterm: under 50 characters, at most five words, none of < > { } [ ] \.
#
# Removing a term doesn't delete the row: it sets suppressed_at, a tombstone,
# so neither harvesting nor the built-in resident names can bring it back.
# Only a person or resident adding it again lifts the tombstone.
class TranscriptionGlossaryTerm < ApplicationRecord

  SOURCES = %w[manual correction harvested].freeze
  MAX_LENGTH = 49
  MAX_WORDS = 5
  FORBIDDEN_CHARACTERS = /[<>{}\[\]\\]/

  belongs_to :account
  belongs_to :created_by_user, class_name: "User", optional: true
  belongs_to :created_by_agent, class_name: "Agent", optional: true

  validates :term, presence: true, length: { maximum: MAX_LENGTH }
  validates :source, inclusion: { in: SOURCES }
  validates :normalized_term, uniqueness: { scope: :account_id }
  validate :within_scribe_limits

  before_validation :normalize

  scope :active, -> { where(suppressed_at: nil) }
  scope :suppressed, -> { where.not(suppressed_at: nil) }

  def self.normalize(term)
    term.to_s.unicode_normalize(:nfkc).squish.downcase
  end

  def self.clean(term)
    term.to_s.unicode_normalize(:nfkc).squish
  end

  def suppressed?
    suppressed_at.present?
  end

  def suppress!
    update!(suppressed_at: Time.current, pinned: false)
  end

  def as_json(*)
    {
      id: to_param,
      term:,
      source:,
      pinned:,
      sightings_count:,
      last_seen_at:,
      created_at:,
      created_by: created_by_agent&.name || created_by_user&.display_name
    }
  end

  private

  def normalize
    self.term = self.class.clean(term)
    self.normalized_term = self.class.normalize(term)
  end

  def within_scribe_limits
    errors.add(:term, "can have at most #{MAX_WORDS} words") if term.to_s.split.size > MAX_WORDS
    errors.add(:term, "can't contain < > { } [ ] or \\") if term.to_s.match?(FORBIDDEN_CHARACTERS)
  end

end
