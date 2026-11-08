class StoneAddress < ApplicationRecord

  WORDS = Rails.root.join("config/stone_words.txt").read.lines.map { |word| word.strip.freeze }.freeze
  CAPACITY = WORDS.length**3
  MAX_ATTEMPTS = 100

  class Exhausted < StandardError; end

  belongs_to :stone, optional: true

  validates :name, presence: true, format: { with: /\A[a-z]+-[a-z]+-[a-z]+\z/ }, length: { maximum: 63 }
  validate :reservation_is_immutable, on: :update
  before_destroy :keep_reservation

  # The caller serializes lazy allocation with the stone's row lock. Unique
  # indexes are the final arbiter for both names and one address per stone.
  def self.reserve!(stone:)
    raise ArgumentError, "A persisted stone is required" unless stone.is_a?(Stone) && stone.persisted?
    existing = find_by(stone_id: stone.id)
    return existing if existing

    MAX_ATTEMPTS.times do
      begin
        # A collision must roll back its own savepoint before we rescue it;
        # otherwise PostgreSQL leaves the caller's transaction unusable.
        return transaction(requires_new: true) { create!(stone: stone, name: random_name) }
      rescue ActiveRecord::RecordNotUnique
        existing = find_by(stone_id: stone.id)
        return existing if existing
      end
    end

    raise Exhausted, "Could not reserve a soul stone hostname after #{MAX_ATTEMPTS} attempts. " \
      "The namespace may be crowded; retry later or ask a site administrator to review capacity."
  end

  def self.random_name
    Array.new(3) { WORDS.fetch(SecureRandom.random_number(WORDS.length)) }.join("-")
  end

  private

  def reservation_is_immutable
    errors.add(:name, "cannot change once reserved") if will_save_change_to_name?
    if will_save_change_to_stone_id? && stone_id.present?
      errors.add(:stone, "cannot replace a reservation's original stone")
    end
  end

  def keep_reservation
    errors.add(:base, "Stone hostname reservations are permanent")
    throw :abort
  end

end
