# Point-in-time measurements of the house for the site dashboard: host load,
# CPU, memory and disk every five minutes, Hetzner VM CPU, and daily resident
# disk, Restic bytes stored in S3, and the prices used to cost them.
class HouseSample < ApplicationRecord

  KINDS = %w[host hetzner_vm resident_disk restic_storage pricing].freeze
  # Five-minute kinds are kept for this long; daily kinds are kept for good.
  FINE_RETENTION = 35.days
  FINE_KINDS = %w[host hetzner_vm].freeze

  belongs_to :agent, optional: true

  validates :kind, inclusion: { in: KINDS }
  validates :sampled_at, presence: true

  scope :of_kind, ->(kind) { where(kind:) }

  def self.prune!(now: Time.current)
    where(kind: FINE_KINDS, sampled_at: ...(now - FINE_RETENTION)).delete_all
  end

  # The newest sample of a kind for each agent (or subject).
  def self.latest_per(column, kind)
    of_kind(kind).select("DISTINCT ON (#{connection.quote_column_name(column)}) house_samples.*")
                 .order(column, sampled_at: :desc)
  end

end
