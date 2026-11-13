# Whether Hetzner could sell each small shared server type, per location, at
# each five-minute check (HetznerAvailabilityCheckJob). available is NULL on
# rows written when the check itself failed or the type was not listed; those
# carry the reason in error.
class HetznerAvailabilitySample < ApplicationRecord

  TYPES = %w[cx23 cx33 cx43 cx53 cax11 cax21 cax31 cax41].freeze
  # Grouped the way Daniel asked: each CX size with its ARM sibling.
  PAIRS = [ %w[cx23 cax11], %w[cx33 cax21], %w[cx43 cax31], %w[cx53 cax41] ].freeze

  validates :checked_at, presence: true
  validates :server_type, inclusion: { in: TYPES }

  # Stores one check. availability is HetznerCloudClient#server_type_availability.
  def self.record!(availability, at:)
    rows = TYPES.flat_map do |type|
      places = availability[type]
      if places.blank?
        [ { server_type: type, location: nil, available: nil, error: "not_listed" } ]
      else
        places.sort.map { |location, available| { server_type: type, location:, available: available == true, error: nil } }
      end
    end
    insert_rows!(rows, at)
  end

  # Stores a check that could not ask Hetzner: one row per type, available NULL.
  def self.record_failure!(error, at:)
    insert_rows!(TYPES.map { |type| { server_type: type, location: nil, available: nil, error: error.to_s.first(100) } }, at)
  end

  def self.insert_rows!(rows, at)
    now = Time.current
    insert_all!(rows.map { |row| row.merge(checked_at: at, created_at: now) })
  end
  private_class_method :insert_rows!

  # The newest checks, newest first:
  # [{ at:, types: { "cx23" => { available: ["nbg1"], error: nil }, ... } }]
  def self.recent_checks(limit = 100)
    times = distinct.order(checked_at: :desc).limit(limit).pluck(:checked_at)
    rows = where(checked_at: times).order(:location).pluck(:checked_at, :server_type, :location, :available, :error)
    by_time = rows.group_by(&:first)
    times.map do |time|
      types = TYPES.index_with { { available: [], error: nil } }
      by_time.fetch(time, []).each do |_time, type, location, available, error|
        types[type][:available] << location if available
        types[type][:error] ||= error
      end
      { at: time, types: }
    end
  end

  # One series per pair since a time: [{ label:, types:, points: [[time, 1|0|nil]] }].
  # A point is 1 when either type of the pair was available in any location,
  # 0 only when both types were checked and neither was, and nil otherwise:
  # one unchecked type leaves the pair unknown, never down.
  def self.pair_series(since)
    flags = where(checked_at: since..).group(:checked_at, :server_type).order(:checked_at)
      .pluck(:checked_at, :server_type, Arel.sql("bool_or(available)"))
    by_time = flags.group_by(&:first).transform_values { |list| list.to_h { |_time, type, any| [ type, any ] } }

    PAIRS.map do |pair|
      points = by_time.map { |time, types| [ time, pair_value(pair.map { |type| types[type] }) ] }
      { label: pair.map(&:upcase).join(" + "), types: pair, points: }
    end
  end

  def self.pair_value(values)
    return 1 if values.include?(true)
    return 0 if values.all?(false)

    nil
  end

end
