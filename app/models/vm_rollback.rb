# One attempt to bring a resident back from its server to the house (#426
# 3C rollback wiring). Driven by Agents::VmMigration::Rollback.
#
#   stopping      generation reserved, stop_resident sent to the server
#   snapshotting  rollback_snapshot sent, for this generation
#   restoring     the house is restoring and verifying the five homes
#   committed     the swap committed: volume map and placement are the
#                 house's; the container is not yet proved on the new map
#   recovered     the container's mounts were read back as this swap's map
#   failed        stopped short of the swap; the resident is as it was,
#                 stopped and paused on its server
class VmRollback < ApplicationRecord

  PHASES = %w[stopping snapshotting restoring committed recovered failed].freeze
  OPEN = %w[stopping snapshotting restoring committed].freeze

  belongs_to :agent
  belongs_to :agent_placement
  belongs_to :requested_by, class_name: "User", optional: true
  belongs_to :stop_command, class_name: "RunnerCommand", optional: true
  belongs_to :snapshot_command, class_name: "RunnerCommand", optional: true

  validates :phase, inclusion: { in: PHASES }
  validates :generation, numericality: { only_integer: true, greater_than: 0 }

  scope :open, -> { where(phase: OPEN) }

  def open? = OPEN.include?(phase)
  def recovered? = phase == "recovered"

end
