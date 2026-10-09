# One instruction for one host runner (#238). Rails never calls a VM: the
# runner polls, gets at most one command, and answers it with a signed result.
#
# A command belongs to one enrollment, one placement and the placement
# generation it was issued under. The runner refuses older generations, and
# the house refuses to hand them out. "done" means the runner carried the
# command out; for submit_turn that is the trigger's answer, not turn
# completion. "unknown" means the effect may or may not have happened (the
# runner restarted mid-command, or something unexpected broke): a turn in that
# state is reconciled by its dispatch id, never resubmitted.
class RunnerCommand < ApplicationRecord

  KINDS = %w[start_resident stop_resident submit_turn turn_status cancel_turn backup_resident].freeze
  STATES = %w[queued delivered done failed refused unknown].freeze
  TERMINAL = %w[done failed refused unknown].freeze
  OUTCOMES = %w[done failed refused unknown].freeze
  # A delivered command with no answer is handed out again after this. The
  # runner remembers what it answered, so redelivery never reruns it.
  REDELIVER_AFTER = 2.minutes
  RESULT_BYTES = 64.kilobytes

  encrypts :payload_json

  belongs_to :runner_enrollment
  belongs_to :agent_placement
  belongs_to :resident_turn, optional: true

  validates :public_id, presence: true, format: { with: /\A[0-9a-f]{32}\z/ }
  validates :kind, inclusion: { in: KINDS }
  validates :state, inclusion: { in: STATES }
  validates :generation, numericality: { only_integer: true, greater_than_or_equal_to: 1 }
  validate :placement_matches_enrollment

  def self.enqueue!(enrollment:, kind:, payload:, resident_turn: nil)
    # Read the placement fresh: a cached association could stamp a new
    # command with a generation that is already stale.
    placement = AgentPlacement.uncached { AgentPlacement.find(enrollment.agent_placement_id) }
    raise ArgumentError, "unknown command kind: #{kind}" unless KINDS.include?(kind)
    raise ArgumentError, "payload must be a hash" unless payload.is_a?(Hash)

    create!(
      public_id: SecureRandom.hex(16),
      runner_enrollment: enrollment,
      agent_placement: placement,
      generation: placement.generation,
      kind:,
      payload_json: payload.to_json,
      resident_turn:
    )
  end

  # Called under the enrollment's row lock. The oldest command that is still
  # queued, or delivered and unanswered for longer than REDELIVER_AFTER.
  def self.next_for(enrollment, now:)
    where(runner_enrollment_id: enrollment.id)
      .where("state = 'queued' OR (state = 'delivered' AND delivered_at < ?)", now - REDELIVER_AFTER)
      .order(:id).lock.first
  end

  def terminal? = TERMINAL.include?(state)
  def delivered? = state == "delivered"

  def deliver!(now:)
    update!(state: "delivered", delivered_at: now, delivery_count: delivery_count + 1)
    envelope
  end

  def envelope
    { "id" => public_id, "kind" => kind, "generation" => generation, "payload" => JSON.parse(payload_json.to_s) }
  end

  # The first answer wins; a repeated answer (lost reply, redelivery) changes
  # nothing. The payload is dropped once answered, so tokens sent to the VM do
  # not stay in the house database longer than needed.
  def record_result!(result, now:)
    return false if terminal?

    result = result.is_a?(Hash) ? result.slice("outcome", "error", "result") : {}
    result = { "outcome" => "unknown", "error" => "result too large" } if result.to_json.bytesize > RESULT_BYTES
    outcome = OUTCOMES.include?(result["outcome"]) ? result["outcome"] : "unknown"
    update!(state: outcome, result:, finished_at: now, payload_json: nil)
    true
  end

  # Refused here without ever reaching the runner.
  def refuse_locally!(reason, now:)
    update!(state: "refused", result: { "outcome" => "refused", "error" => reason }, finished_at: now, payload_json: nil)
  end

  private

  def placement_matches_enrollment
    return if runner_enrollment.nil? || runner_enrollment.agent_placement_id == agent_placement_id

    errors.add(:agent_placement, "must be the enrollment's placement")
  end

end
