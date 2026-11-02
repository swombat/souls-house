# One account archive brought into an account (docs/features/account-portability.md).
# The uploaded bytes are kept until the import finishes; the preview names
# the SHA-256 of exactly those bytes, and the import refuses anything else.
# `ledger` records every created thing by its archive key, so a retried job
# picks up where it stopped instead of creating a second copy.
class AccountImport < ApplicationRecord

  include ObfuscatesId

  STATUSES = %w[uploaded validating previewed invalid importing imported failed].freeze

  belongs_to :account
  belongs_to :user
  has_one_attached :upload

  validates :status, inclusion: { in: STATUSES }

  scope :recent_first, -> { order(created_at: :desc) }

  def ledger_for(section) = ledger.fetch(section, {})

  def as_json(*)
    {
      id: to_param, status: status, preview: preview.presence, error: error,
      result: ledger.slice("summary").presence && ledger["summary"],
      created_at: created_at&.iso8601, finished_at: finished_at&.iso8601
    }
  end

end
