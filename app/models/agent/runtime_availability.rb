module Agent::RuntimeAvailability

  extend ActiveSupport::Concern

  HOSTED_RUNTIMES = %w[external offline provisioning].freeze
  CONVERSATION_RUNTIMES = %w[external offline].freeze
  RETIRED_RUNTIMES = %w[deprecated inline migrating].freeze

  class Unavailable < ArgumentError

    attr_reader :code

    def initialize(message, code: "agent_unavailable")
      @code = code
      super(message)
    end

  end

  included do
    scope :hosted, -> { where(runtime: HOSTED_RUNTIMES) }
    scope :eligible_for_conversation, -> { active.where(runtime: CONVERSATION_RUNTIMES).not_billing_held }
    # Asleep: the resident's paid plan lapsed (docs/proposals/2026-10-07-stripe-billing.md,
    # "The hold boundary"). Billing never touches paused or active.
    scope :not_billing_held, -> { where.not(id: ResidentEntitlement.where(state: "held").select(:agent_id)) }
  end

  # Asleep because its paid plan lapsed. Nothing new starts until it is paid
  # again; the owner's own pause and every other stop reason are separate.
  def billing_held?
    return false if new_record?

    ResidentEntitlement.where(agent_id: id, state: "held").exists?
  end

  # Legacy values fail closed before the reviewed one-time data transition too.
  def deprecated?
    runtime.in?(RETIRED_RUNTIMES)
  end

  def hosted?
    runtime.in?(HOSTED_RUNTIMES)
  end

  def eligible_for_conversation?
    active? && runtime.in?(CONVERSATION_RUNTIMES) && github_resident_import&.approval_error.nil? && !billing_held?
  end

  def unavailability_reason
    return "agent_deprecated" if deprecated?
    return "agent_inactive" unless active?
    return "github_import_approval_required" if github_resident_import&.approval_error
    return "agent_provisioning" if provisioning?
    return "billing_hold" if billing_held?
    "agent_unavailable" unless eligible_for_conversation?
  end

  def require_conversation_runtime!
    github_resident_import&.require_approval!
    return if eligible_for_conversation?

    if billing_held?
      raise Unavailable.new("#{name} is asleep: the payment for their plan has lapsed", code: "billing_hold")
    end

    raise Unavailable.new(
      "#{name} is unavailable#{deprecated? ? ': its inline runtime has been retired' : ''}",
      code: unavailability_reason
    )
  end

end
