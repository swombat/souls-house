# One attempt to create one Boat sandbox for one placement (slice 2, ePokyY).
#
# The Boat twin of CloudProcurementOperation, with the same states and the
# same rule: intent is committed before any HTTP request, there is one create
# POST per operation, and an ambiguous create is reconciled against what Boat
# has, never assumed away or retried. The create also carries public_id as its
# Idempotency-Key, so even a duplicated request could not buy a second
# sandbox; it is not used to retry, because the enrollment token's plaintext
# exists only in the first request's body.
#
# States are CloudProcurementOperation's; "reconciling" waits for the sandbox
# to be awake, and "provisioned" is verified, not runtime-ready.
class BoatProcurementOperation < ApplicationRecord

  STATES = CloudProcurementOperation::STATES
  RESOLVED_STATES = CloudProcurementOperation::RESOLVED_STATES
  UNRESOLVED_STATES = (STATES - RESOLVED_STATES).freeze
  SANDBOX_SIZES = %w[small].freeze

  belongs_to :agent_placement
  belongs_to :requested_by, class_name: "User"
  has_one :runner_enrollment, inverse_of: false

  state_machine :state, initial: :planned, action: nil do
    state(*STATES.map(&:to_sym))

    event :submit_purchase do
      transition planned: :create_in_flight
    end

    event :refuse_purchase do
      transition [ :planned, :create_in_flight ] => :refused
    end

    event :lose_create_result do
      transition [ :create_in_flight, :unknown ] => :unknown
    end

    event :record_sandbox do
      transition [ :create_in_flight, :unknown ] => :reconciling
    end

    event :require_review do
      transition [ :create_in_flight, :unknown, :reconciling, :deleting ] => :needs_review
    end

    event :confirm_provisioning do
      transition reconciling: :provisioned
    end

    event :request_cleanup do
      transition [ :provisioned, :reconciling, :needs_review ] => :deleting
    end

    event :confirm_deletion do
      transition deleting: :deleted
    end
  end

  validates :public_id, :provider_name, :approval_reference, presence: true
  validates :sandbox_size, inclusion: { in: SANDBOX_SIZES }
  validates :provider_sandbox_id, format: { with: BoatClient::SANDBOX_ID }, allow_nil: true
  validate :placement_is_boat

  scope :unresolved, -> { where(state: UNRESOLVED_STATES) }

  def unresolved? = UNRESOLVED_STATES.include?(state)

  # BoatProcurement holds the operation's lock and supplies the evidence.
  def transition_to!(target, **attributes)
    case target
    when "create_in_flight" then submit_purchase!
    when "refused" then refuse_purchase!
    when "unknown" then lose_create_result!
    when "reconciling" then record_sandbox!
    when "needs_review" then require_review!
    when "provisioned" then confirm_provisioning!
    when "deleting" then request_cleanup!
    when "deleted" then confirm_deletion!
    else raise ArgumentError, "Unknown purchase destination: #{target}"
    end
    update!(attributes)
  end

  private

  private :submit_purchase, :submit_purchase!, :refuse_purchase, :refuse_purchase!, :lose_create_result, :lose_create_result!,
    :record_sandbox, :record_sandbox!, :require_review, :require_review!,
    :confirm_provisioning, :confirm_provisioning!, :request_cleanup, :request_cleanup!,
    :confirm_deletion, :confirm_deletion!

  def placement_is_boat
    errors.add(:agent_placement, "must be a Boat placement") unless agent_placement&.backend == "boat"
  end

end
