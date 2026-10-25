require "uri"

class AgentPlacement < ApplicationRecord

  BACKENDS = %w[local hetzner_cloud].freeze
  # staged: an archive import's or a migration's VM intent, waiting for
  # Activate. It has no server, no admission and no cap slot, and as a VM
  # placement it is never run by the local runtime (RuntimeLocation).
  STATES = %w[staged pending ready failed retired].freeze
  # migration: an existing house resident moving to its own server (#426),
  # seeded per role like an archive import from its own stopped house home.
  KINDS = %w[birth archive_import github_import migration].freeze
  # Kinds seeded per role from AgentImportStage rows.
  STAGED_ROLE_KINDS = %w[archive_import migration].freeze

  belongs_to :agent, inverse_of: :placement
  # Who created the resident whose birth admitted this placement (#246).
  belongs_to :birth_requested_by, class_name: "User", optional: true
  # Purchases are history: a placement that has had one is never deleted.
  has_many :cloud_procurement_operations, dependent: :restrict_with_exception

  validates :agent_id, uniqueness: true
  validates :backend, inclusion: { in: BACKENDS }
  validates :state, inclusion: { in: STATES }
  validates :kind, inclusion: { in: KINDS }, allow_nil: true
  validates :kind, absence: true, if: -> { backend == "local" }
  validate :staged_holds_nothing, if: -> { state == "staged" }
  validates :house_runtime_ready_at, absence: true, unless: -> { kind == "migration" }
  # Confirmed hosting geography, set when procurement verifies a server.
  validates :location, inclusion: { in: CloudProcurementOperation::EU_LOCATIONS }, allow_nil: true
  validates :location, absence: true, if: -> { backend == "local" }
  # Reserved for future fencing; no runtime currently enforces this generation.
  validates :generation, numericality: { only_integer: true, greater_than_or_equal_to: 1 }
  validates :provider_server_id,
    numericality: { only_integer: true, greater_than: 0 }, uniqueness: true, allow_nil: true
  validates :provider_server_id, :runtime_endpoint, absence: true, if: -> { backend == "local" }
  # A ready VM placement needs its server. It needs no endpoint: the house
  # never calls the VM, whose runner polls for commands (#238).
  validates :provider_server_id, presence: true, if: -> { backend == "hetzner_cloud" && state == "ready" }
  validate :runtime_endpoint_is_https

  def vm_birth? = backend == "hetzner_cloud" && admitted_by_setting_at.present?
  def staged? = state == "staged"
  def migration? = backend == "hetzner_cloud" && kind == "migration"
  def cleanup_requested? = cleanup_requested_at.present?

  # Records why this placement's server must go. Never deletes anything
  # itself; VmCleanupJob does that, until the provider confirms.
  def request_cleanup!(reason, now: Time.current)
    with_lock do
      update!(cleanup_requested_at: now, cleanup_reason: reason.to_s.first(255)) unless cleanup_requested?
    end
  end

  private

  def staged_holds_nothing
    unless backend == "hetzner_cloud" && STAGED_ROLE_KINDS.include?(kind)
      errors.add(:state, "staged is only for a VM archive import or migration")
    end
    errors.add(:state, "staged holds no server") if provider_server_id.present? || location.present?
    errors.add(:state, "staged is not admitted") if admitted_by_setting_at.present? || birth_deadline_at.present?
  end

  def runtime_endpoint_is_https
    return if runtime_endpoint.nil?

    endpoint = URI.parse(runtime_endpoint)
    unless endpoint.is_a?(URI::HTTPS) && endpoint.host.present? &&
        endpoint.userinfo.nil? && endpoint.query.nil? && endpoint.fragment.nil? &&
        [ "", "/" ].include?(endpoint.path)
      errors.add(:runtime_endpoint, "must be an HTTPS root URL without credentials, query or fragment")
    end
  rescue URI::InvalidURIError
    errors.add(:runtime_endpoint, "must be an HTTPS URL")
  end

end
