# One account archive being built, or built (docs/features/account-portability.md).
# The ZIP sits in private storage until it expires; only the account's owners
# (and site administrators) can download it, never through a public blob URL.
class AccountExport < ApplicationRecord

  include ObfuscatesId

  LIFETIME = 7.days
  STATUSES = %w[queued running ready failed expired].freeze

  belongs_to :account
  belongs_to :user
  has_one_attached :archive

  validates :status, inclusion: { in: STATUSES }

  scope :recent_first, -> { order(created_at: :desc) }

  def downloadable? = status == "ready" && archive.attached? && expires_at&.future?

  def as_json(*)
    {
      id: to_param, status: status, include_conversations: include_conversations, progress: progress,
      partial: summary["partial"], residents: summary["residents"], omitted: summary["omitted"],
      byte_size: archive.attached? ? archive.blob.byte_size : nil, error: error,
      created_at: created_at&.iso8601, finished_at: finished_at&.iso8601, expires_at: expires_at&.iso8601,
      downloadable: downloadable?
    }
  end

end
