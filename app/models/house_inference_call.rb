class HouseInferenceCall < ApplicationRecord

  # Charged to exactly one ledger: a legacy user grant, or a resident's paid
  # plan (DB check house_calls_one_ledger). The resident it was made for is
  # recorded at creation; older grant-only rows have none.
  belongs_to :house_inference_grant, optional: true
  belongs_to :resident_entitlement, optional: true
  belongs_to :agent, optional: true
  attr_readonly :house_inference_grant_id, :resident_entitlement_id, :agent_id, :free_pool
  validates :charge_usd, numericality: { greater_than_or_equal_to: 0 }

  scope :on_grants, -> { where.not(house_inference_grant_id: nil) }
  # Calls the house paid for out of free allowances (per-user grants and free
  # hosting's own allowance). They share the house-wide ceiling. Fixed when the
  # call is reserved, so a plan starting or ending later doesn't move past
  # spend between pools.
  scope :free, -> { where(free_pool: true) }

  # Callers that reserve set it; otherwise it is decided from the ledger once,
  # at creation, and never changes.
  before_validation on: :create do
    self.free_pool = house_inference_grant_id.present? || resident_entitlement&.complimentary? || false if free_pool.nil?
  end

  # Idempotent. Missing/ambiguous usage retains the conservative charge; a crash
  # leaves pending admission blocked until an operator reconciles that call.
  def settle!(usage = nil, upstream_id: nil)
    with_lock do
      return unless status == 'pending'
      # BYOK and rounding (never down) live in HouseInference::UsageCost. A
      # BYOK call without a usable upstream cost fails closed as before.
      cost, byok = HouseInference::UsageCost.call(usage)
      known = !cost.nil?
      outcome = if (byok && !known) || (known && cost > charge_usd)
        'overrun'
      else
        known ? 'settled' : 'uncertain'
      end
      update!(charge_usd: known ? cost : charge_usd, status: outcome, upstream_id: upstream_id)
    end
  end

end
