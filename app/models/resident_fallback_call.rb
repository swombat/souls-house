# One paid provider call made on a resident's fallback (#690). The call
# reserves its worst case against the owner's cap before it is sent, under the
# policy's row lock, and settles to the provider-reported charge. Rates are
# snapshotted here so history is never repriced.
class ResidentFallbackCall < ApplicationRecord

  STATUSES = %w[pending settled not_sent unresolved].freeze

  belongs_to :agent
  belongs_to :resident_fallback_turn, optional: true

  validates :status, inclusion: { in: STATUSES }
  validates :upstream_model, :period_start, :max_price, presence: true
  validates :reservation_usd, numericality: { greater_than_or_equal_to: 0 }

  def self.committed_usd(agent_id:, period_start:)
    where(agent_id: agent_id, period_start: period_start).sum(
      Arel.sql("CASE status WHEN 'settled' THEN charge_usd WHEN 'not_sent' THEN 0 ELSE reservation_usd END")
    ).to_d
  end

  # The provider reported what the call cost.
  def settle!(charge_usd, source:, upstream_id: nil)
    update!(status: "settled", charge_usd: charge_usd, cost_source: source, upstream_id: upstream_id || self.upstream_id)
  end

  # The request provably never left the house (refused before it was sent):
  # it costs nothing. Anything that may have reached the provider is never
  # released this way, refused or not: "no output arrived" is not proof that
  # nothing was billed. Unlike house-funded calls, the owner's key pays here.
  def not_sent!
    raise ArgumentError, "only a pending call can be marked not sent" unless status == "pending"

    update!(status: "not_sent", charge_usd: 0)
  end

  # The call may have reached the provider and its charge isn't known (an
  # HTTP refusal, a disconnect, a truncated or uncosted response): the whole
  # reservation stays counted until billing is resolved.
  def unresolved!(http_status: nil, upstream_id: nil)
    update!(status: "unresolved", http_status: http_status, upstream_id: upstream_id || self.upstream_id)
  end

end
