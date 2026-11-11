class WorkCompletionPermission < ApplicationRecord

  belongs_to :chat
  belongs_to :user

  scope :available, -> { where(revoked_at: nil, consumed_at: nil) }

end
