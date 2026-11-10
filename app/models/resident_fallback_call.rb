# One paid provider call made on a resident's fallback (#690). The call
# reserves its worst case against the owner's cap before it is sent, under the
# policy's row lock, and settles to the provider-reported charge. Rates are
# snapshotted here so history is never repriced.
class ResidentFallbackCall < ApplicationRecord

  STATUSES = %w[pending settled not_sent unresolved].freeze

  belongs_to :agent
  belongs_to :resident_fallback_turn, optional: true

  validates :status, inclusion: { in: STATUSES }
  validates :upstream_model, :admitted_at, :max_price, presence: true
  validates :reservation_usd, numericality: { greater_than_or_equal_to: 0 }
  validates :charge_usd, presence: true, if: -> { status == "settled" }

  # Calls admitted inside [from, to). The window is the policy's *current*
  # period, computed at read time from each call's admission time, so a
  # change of cap period counts every call inside the new window.
  def self.committed_usd(agent_id:, from:, to:)
    where(agent_id: agent_id, admitted_at: from...to).sum(
      # A settled row always has a charge (validation + check constraint);
      # the COALESCE is belt and braces so a NULL can never count as zero.
      Arel.sql("CASE status WHEN 'settled' THEN COALESCE(charge_usd, reservation_usd) WHEN 'not_sent' THEN 0 ELSE reservation_usd END")
    ).to_d
  end

  # The provider reported what the call cost. A known charge is required: a
  # call whose cost isn't known is unresolved!, never settled at nothing.
  # Settlement wins over any state except an earlier settlement (billing can
  # resolve an unresolved call, or contradict a not_sent one); a second
  # settlement is ignored. Returns whether this call changed the row.
  def settle!(charge_usd, source:, upstream_id: nil)
    raise ArgumentError, "a settled call needs a known charge; use unresolved!" if charge_usd.nil?

    charge = BigDecimal(charge_usd.to_s)
    raise ArgumentError, "a charge can't be negative" if charge.negative?

    with_lock do
      next false if status == "settled"

      update!(status: "settled", charge_usd: charge, cost_source: source, upstream_id: upstream_id || self.upstream_id)
    end
  end

  # The request provably never left the house (refused before it was sent):
  # it costs nothing. Anything that may have reached the provider is never
  # released this way, refused or not: "no output arrived" is not proof that
  # nothing was billed. Unlike house-funded calls, the owner's key pays here.
  # Only a call still pending (re-read under the row lock) can be released;
  # a late callback on a settled or unresolved call changes nothing.
  def not_sent!
    with_lock do
      next false unless status == "pending"

      update!(status: "not_sent", charge_usd: 0)
    end
  end

  # The call may have reached the provider and its charge isn't known (an
  # HTTP refusal, a disconnect, a truncated or uncosted response): the whole
  # reservation stays counted until billing is resolved. Only from pending:
  # it never overwrites a known settlement.
  def unresolved!(http_status: nil, upstream_id: nil)
    with_lock do
      next false unless status == "pending"

      update!(status: "unresolved", http_status: http_status, upstream_id: upstream_id || self.upstream_id)
    end
  end

end
