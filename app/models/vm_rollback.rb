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
#
# Releasing the server it left behind (RollbackRelease) is recorded here too,
# not on the placement, which is the house's again: release_requested_at is
# the intent, released_at the provider's confirmed absence.
class VmRollback < ApplicationRecord

  PHASES = %w[stopping snapshotting restoring committed recovered failed].freeze
  OPEN = %w[stopping snapshotting restoring committed].freeze

  belongs_to :agent
  belongs_to :agent_placement
  belongs_to :requested_by, class_name: "User", optional: true
  belongs_to :release_requested_by, class_name: "User", optional: true
  belongs_to :stop_command, class_name: "RunnerCommand", optional: true
  belongs_to :snapshot_command, class_name: "RunnerCommand", optional: true

  validates :phase, inclusion: { in: PHASES }
  validates :generation, numericality: { only_integer: true, greater_than: 0 }

  scope :open, -> { where(phase: OPEN) }
  scope :releasing, -> { where.not(release_requested_at: nil).where(released_at: nil) }

  def open? = OPEN.include?(phase)
  def recovered? = phase == "recovered"
  def release_requested? = release_requested_at.present?
  def released? = released_at.present?

  # The purchases on the server this attempt brought the resident back from,
  # as recorded before the switch. Nothing the placement acquires later.
  def source_operations
    CloudProcurementOperation.where(id: Array(source["procurement_operation_ids"]), agent_placement_id:)
  end

  # Whether CloudProcurement may delete this operation's server for this
  # attempt's release: asked for, recovered, and one of its own purchases.
  def releases?(operation)
    release_requested? && !released? && recovered? &&
      operation.agent_placement_id == agent_placement_id &&
      Array(source["procurement_operation_ids"]).include?(operation.id)
  end

end
