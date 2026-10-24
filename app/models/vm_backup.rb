class VmBackup < ApplicationRecord

  belongs_to :agent
  belongs_to :runner_command
  belongs_to :agent_backup_snapshot, optional: true

  validates :state, inclusion: { in: %w[pending verified failed] }
  scope :holding, -> { where(released_at: nil) }

end
