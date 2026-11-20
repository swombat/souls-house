# One ElevenLabs render: which account it was for, which key paid for it
# ("account": the account's own; "house": the house's, under
# Account#house_eleven_labs_key), on which surface, and how many characters
# were sent. The text itself and the key are never stored.
class SpeechCharge < ApplicationRecord

  SURFACES = %w[listen voice_mode].freeze

  belongs_to :account
  belongs_to :agent, optional: true
  belongs_to :message, optional: true

  validates :surface, inclusion: { in: SURFACES }
  validates :key_source, inclusion: { in: SpeechEngine::KEY_SOURCES }
  validates :characters, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  scope :on_house_key, -> { where(key_source: SpeechEngine::HOUSE_KEY) }

  def self.record!(key:, account:, surface:, text:, agent: nil, message: nil)
    create!(account:, agent:, message:, surface:, key_source: key.source, characters: text.to_s.length)
  rescue ActiveRecord::ActiveRecordError => e
    # A missing ledger row must not cost the person their audio.
    Rails.logger.warn("[SpeechCharge] not recorded for account #{account&.id}: #{e.class}: #{e.message}")
    nil
  end

end
