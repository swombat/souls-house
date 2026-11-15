# One attempt to move a resident from its server to another one the house
# holds (Agents::ServerMove, eRyZBY). The row records exactly which servers,
# snapshot and provider actions the attempt used, so a retry after a crash
# reads them instead of asking again.
#
# Phases:
#   stopping      turns held; the old server has been asked to shut down
#   snapshotting  the old server is off; Hetzner is copying its disk
#   rebuilding    the house's records point at the new server; Hetzner is
#                 writing the copy onto it
#   verifying     the new server is starting; waiting for its runner
#   moved         the resident runs on the new server. The old server is off
#                 and untouched, and the snapshot is kept
#   reverting     going back: the new server is being stopped and the old
#                 one started
#   reverted      the resident runs on the old server again
#   releasing     the left-behind server and the snapshot are being let go.
#                 Claimed before anything is deleted: from here the move
#                 can no longer be undone, and nothing else can take it back
#   released      the left-behind server's deletion is asked for and the
#                 snapshot is gone
class VmServerMove < ApplicationRecord

  PHASES = %w[stopping snapshotting rebuilding verifying moved reverting reverted releasing released].freeze
  SETTLED_PHASES = %w[moved reverted].freeze
  # A move in one of these holds the resident's turns and its target.
  OPEN_PHASES = %w[stopping snapshotting rebuilding verifying reverting].freeze

  belongs_to :agent
  belongs_to :agent_placement
  belongs_to :requested_by, class_name: "User"
  belongs_to :source_operation, class_name: "CloudProcurementOperation"
  belongs_to :target_operation, class_name: "CloudProcurementOperation"
  belongs_to :runner_enrollment
  belongs_to :set_aside_operation, class_name: "CloudProcurementOperation", optional: true
  belongs_to :release_operation, class_name: "CloudProcurementOperation", optional: true
  belongs_to :released_by, class_name: "User", optional: true

  validates :phase, inclusion: { in: PHASES }
  validates :public_id, :source_server_id, :target_server_id, :phase_started_at, presence: true

  scope :open, -> { where(phase: OPEN_PHASES) }

  def open? = OPEN_PHASES.include?(phase)
  def settled? = SETTLED_PHASES.include?(phase)
  def switched? = switched_at.present?

  # Residents whose turns wait for a move (ResidentTurn.admit!).
  def self.holding_agent_ids
    open.pluck(:agent_id).to_set
  end

  # The server this move left behind, once it is settled: the old one after
  # a move, the new one (which holds a copy of the resident's disk) after
  # going back. It is the purchase this move's own switch set aside, recorded
  # then, never inferred from what a purchase looks like now: a spare this
  # move never wrote to may since have been used and set aside by another
  # move, and is that move's to release (Mira, #979). nil when this move
  # never switched.
  def left_behind_operation
    return nil unless settled?

    operation = set_aside_operation
    operation if operation&.purpose == "move_source" && operation.agent_placement_id.nil?
  end

  def enter!(phase, now: Time.current, **attributes)
    update!(phase:, phase_started_at: now, **attributes)
  end

end
