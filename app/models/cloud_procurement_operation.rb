# One attempt to buy one Hetzner Cloud server for one placement (#191).
#
# The row is the purchase's durable memory. Intent is committed before any
# HTTP request, and nothing here ever sends a second create: after a crash,
# timeout or ambiguous reply the operation is reconciled against what the
# provider actually has, and only an operator moves it out of uncertainty.
#
# States:
#   planned          location and spec fixed; nothing sent; no enrollment yet
#   create_in_flight enrollment minted and intent committed; the one POST may
#                    or may not have left this process
#   reconciling      the provider returned a server; waiting for it to boot
#   provisioned      the server is verified and running. NOT runtime-ready:
#                    the placement stays unavailable to residents
#   unknown          a purchase may exist but none is visible yet
#   refused          the provider (or the house, before sending) refused; no
#                    server was bought
#   needs_review     something did not add up; an operator decides
#   deleting         cleanup accepted; waiting for verified absence
#   deleted          provider absence verified
class CloudProcurementOperation < ApplicationRecord

  STATES = %w[planned create_in_flight reconciling provisioned unknown refused needs_review deleting deleted].freeze
  # Only these free the placement for another purchase.
  RESOLVED_STATES = %w[refused deleted].freeze
  UNRESOLVED_STATES = (STATES - RESOLVED_STATES).freeze
  SERVER_TYPES = %w[cx23 cx33].freeze
  EU_LOCATIONS = %w[fsn1 nbg1 hel1].freeze

  belongs_to :agent_placement
  belongs_to :requested_by, class_name: "User"
  has_one :runner_enrollment, foreign_key: :procurement_operation_id, inverse_of: false

  validates :public_id, :provider_name, :approval_reference, presence: true
  validates :state, inclusion: { in: STATES }
  validates :server_type, inclusion: { in: SERVER_TYPES }
  validates :location, inclusion: { in: EU_LOCATIONS }
  validates :image_id, numericality: { only_integer: true, greater_than: 0 }
  validate :ssh_key_ids_are_positive_integers

  scope :unresolved, -> { where(state: UNRESOLVED_STATES) }

  def unresolved? = UNRESOLVED_STATES.include?(state)

  # Labels let reconciliation find the server; they prove nothing on their own.
  def discovery_labels
    { HetznerCloudClient::OPERATION_LABEL => public_id }
  end

  private

  def ssh_key_ids_are_positive_integers
    ids = ssh_key_ids
    return if ids.is_a?(Array) && ids.any? && ids.all? { |id| id.is_a?(Integer) && id.positive? }

    errors.add(:ssh_key_ids, "must be at least one provider SSH key id")
  end

end
