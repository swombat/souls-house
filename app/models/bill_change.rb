# One change to an account's bill: a resident added, ended or resized, the
# plan changed, the whole bill set to end or kept. Whatever it changes, it is
# the same record and goes through the same three steps
# (docs/proposals/2026-11-14-one-bill.md):
#
#   proposed   what the bill would become (lines), the exact Stripe update
#              that makes it so (params, under idempotency_key) and what the
#              owner was shown (quote). Nothing has been sent; a proposal can
#              be dropped freely.
#   submitted  the owner confirmed that quote and the update was sent. From
#              here it is only ever replayed under its key or read back,
#              never sent again as something new.
#   applied    Stripe's subscription carries the wanted lines and the house's
#              records follow (Billing::BillSync). Or abandoned, with why.
#
# An account has one unresolved change at a time (the partial unique index),
# so an older change can never land over a newer bill.
#
# ops is a list, each one of:
#   { "op" => "add", "agent_id" => 1, "price" => "price_…" }
#   { "op" => "birth", "order" => "<birth order reference>", "price" => "price_…" }
#   { "op" => "end", "agent_id" => 1 }
#   { "op" => "resize", "agent_id" => 1, "price" => "price_…" }
#   { "op" => "plan", "price" => "price_…" }   # nil price: back to Companions
#   { "op" => "end_bill" } / { "op" => "keep_bill" }
# base and lines are { price id => quantity }: the subscription's lines when
# the change was proposed, and the lines it wants.
class BillChange < ApplicationRecord

  STATES = %w[proposed submitted applied abandoned].freeze
  OPS = %w[add birth end resize promote plan end_bill keep_bill].freeze

  belongs_to :account
  belongs_to :requested_by, class_name: "User", optional: true
  has_one :birth_order, class_name: "ResidentBirthOrder", dependent: :nullify

  attr_readonly :account_id, :stripe_subscription_id, :idempotency_key, :ops, :base, :lines, :params, :quote

  validates :state, inclusion: { in: STATES }
  validates :stripe_subscription_id, :idempotency_key, presence: true
  validate { errors.add(:ops, "names an unknown operation") unless ops.is_a?(Array) && ops.all? { |op| op["op"].in?(OPS) } }

  scope :unresolved, -> { where(resolved_at: nil) }
  scope :submitted, -> { unresolved.where(state: "submitted") }

  STATES.each { |name| define_method(:"#{name}?") { state == name } }

  def resolved? = resolved_at.present?
  def wanted = lines.transform_values(&:to_i)
  def ends_bill? = ops.any? { |op| op["op"] == "end_bill" }
  def keeps_bill? = ops.any? { |op| op["op"] == "keep_bill" }

  # What the owner confirms, as a digest of the quote. Key order is not part
  # of it: Postgres returns a jsonb object's keys in its own order.
  def digest = Digest::SHA256.hexdigest(JSON.generate(canonical(quote)))

  def submit!(now: Time.current) = update!(state: "submitted", submitted_at: now)
  def apply!(now: Time.current) = update!(state: "applied", resolved_at: now)
  def abandon!(problem, now: Time.current) = update!(state: "abandoned", problem: problem, resolved_at: now)

  private

  def canonical(value)
    case value
    when Hash then value.map { |key, inner| [ key.to_s, canonical(inner) ] }.sort_by(&:first)
    when Array then value.map { |inner| canonical(inner) }
    else value
    end
  end

end
